import protocol.debug.Types;
import js.node.Buffer;
import js.node.Net;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess.ChildProcessEvent;
import js.node.net.Socket.SocketEvent;
import js.node.stream.Readable.ReadableEvent;
import Protocol;

typedef EvalLaunchRequestArguments = {
	> protocol.debug.Types.LaunchRequestArguments,
	var cwd:String;
	var args:Array<String>;
	var stopOnEntry:Bool;
}

@:keep
class Main extends adapter.DebugSession {
	function traceToOutput(value:Dynamic, ?infos:haxe.PosInfos) {
		var msg = value;
		if (infos != null && infos.customParams != null) {
			msg += " " + infos.customParams.join(" ");
		}
		msg += "\n";
		sendEvent(new adapter.DebugSession.OutputEvent(msg));
	}

	override function initializeRequest(response:InitializeResponse, args:InitializeRequestArguments) {
		// haxe.Log.trace = traceToOutput;
		response.body.supportsSetVariable = true;
		response.body.supportsEvaluateForHovers = true;
		response.body.supportsConditionalBreakpoints = true;
		response.body.supportsExceptionOptions = true;
		response.body.exceptionBreakpointFilters = [
			{filter: "all", label: "All Exceptions"},
			{filter: "uncaught", label: "Uncaught Exceptions"}
		];
		response.body.supportsFunctionBreakpoints = true;
		response.body.supportsConfigurationDoneRequest = true;
		response.body.supportsCompletionsRequest = true;
		sendResponse(response);
		postLaunchActions = [];
	}

	var connection:Connection;
	var postLaunchActions:Array<(Void->Void)->Void>;
	var stopOnEntry:Bool;

	function executePostLaunchActions(callback) {
		function loop() {
			var action = postLaunchActions.shift();
			if (action == null)
				return callback();
			action(loop);
		}
		loop();
	}

	override function launchRequest(response:LaunchResponse, args:LaunchRequestArguments) {
		var args:EvalLaunchRequestArguments = cast args;
		stopOnEntry = args.stopOnEntry;
		var haxeArgs = args.args;
		var cwd = args.cwd;

		function onConnected(socket) {
			trace("Haxe connected!");
			connection = new Connection(socket);
			connection.onEvent = onEvent;

			socket.on(SocketEvent.Error, error -> trace('Socket error: $error'));

			function ready() {
				sendEvent(new adapter.DebugSession.InitializedEvent());
			}

			executePostLaunchActions(function() {
				if (args.stopOnEntry) {
					ready();
					sendResponse(response);
					sendEvent(new adapter.DebugSession.StoppedEvent("entry", 0));
				} else {
					ready();
				}
			});
		}

		function onExit(_, _) {
			sendEvent(new adapter.DebugSession.TerminatedEvent(false));
		}

		var server = Net.createServer(onConnected);
		server.listen(0, function() {
			var port = server.address().port;
			var args = ["--cwd", cwd, "-D", 'eval-debugger=127.0.0.1:$port'].concat(haxeArgs);
			var haxeProcess = ChildProcess.spawn("haxe", args, {stdio: Pipe});
			haxeProcess.stdout.on(ReadableEvent.Data, onStdout);
			haxeProcess.stderr.on(ReadableEvent.Data, onStderr);
			haxeProcess.on(ChildProcessEvent.Exit, onExit);
		});
	}

	function onStdout(data:Buffer) {
		sendEvent(new adapter.DebugSession.OutputEvent(data.toString("utf-8"), stdout));
	}

	function onStderr(data:Buffer) {
		sendEvent(new adapter.DebugSession.OutputEvent(data.toString("utf-8"), stderr));
	}

	var stopContext:StopContext;

	function onEvent<P>(type:NotificationMethod<P>, data:P) {
		switch (type) {
			case Protocol.BreakpointStop:
				stopContext = new StopContext(connection);
				sendEvent(new adapter.DebugSession.StoppedEvent("breakpoint", 0));
			case Protocol.ExceptionStop:
				stopContext = new StopContext(connection);
				var evt = new adapter.DebugSession.StoppedEvent("exception", 0);
				evt.body.text = data.text;
				sendEvent(evt);
		}
	}

	override function scopesRequest(response:ScopesResponse, args:ScopesArguments) {
		stopContext.getScopes(args.frameId, function(scopes) {
			response.body = {scopes: scopes};
			sendResponse(response);
			// stopContext.browseVariables(scopes);
		});
	}

	override function variablesRequest(response:VariablesResponse, args:VariablesArguments) {
		stopContext.getVariables(args.variablesReference, function(vars) {
			response.body = {variables: vars};
			sendResponse(response);
		});
	}

	override function setVariableRequest(response:SetVariableResponse, args:SetVariableArguments) {
		stopContext.setVariable(args.variablesReference, args.name, args.value, function(varInfo) {
			if (varInfo != null)
				response.body = {value: varInfo.value};
			sendResponse(response);
		});
	}

	override function stepInRequest(response:StepInResponse, args:StepInArguments) {
		connection.sendCommand(Protocol.StepIn, {}, function(error, _) {
			respond(response, error, function() {});
			sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
		});
	}

	override function stepOutRequest(response:StepOutResponse, args:StepOutArguments) {
		connection.sendCommand(Protocol.StepOut, {}, function(error, _) {
			respond(response, error, function() {});
			sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
		});
	}

	override function nextRequest(response:NextResponse, args:NextArguments) {
		connection.sendCommand(Protocol.Next, {}, function(error, _) {
			respond(response, error, function() {});
			sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
		});
	}

	override function stackTraceRequest(response:StackTraceResponse, args:StackTraceArguments) {
		connection.sendCommand(Protocol.StackTrace, {}, function(error, result) {
			respond(response, error, function() {
				var r:Array<StackFrame> = [];
				for (info in result) {
					if (info.artificial) {
						r.push({
							id: info.id,
							name: "Internal",
							line: 0,
							column: 0,
							presentationHint: label,
						});
					} else {
						r.push({
							id: info.id,
							name: info.name,
							source: {path: info.source},
							line: info.line,
							column: info.column,
							endLine: info.endLine,
							endColumn: info.endColumn,
						});
					}
				}
				response.body = {
					stackFrames: r
				};
			});
		});
	}

	override function threadsRequest(response:ThreadsResponse) {
		// TODO: support other threads?
		response.body = {threads: [{id: 0, name: "Interp"}]};
		sendResponse(response);
	}

	override function continueRequest(response:ContinueResponse, args:ContinueArguments) {
		connection.sendCommand(Protocol.Continue, {}, (error, _) -> respond(response, error, () -> {}));
	}

	override function setBreakPointsRequest(response:SetBreakpointsResponse, args:SetBreakpointsArguments) {
		if (connection == null)
			postLaunchActions.push(cb -> doSetBreakpoints(response, args, cb));
		else
			doSetBreakpoints(response, args, null);
	}

	override function setFunctionBreakPointsRequest(response:SetFunctionBreakpointsResponse, args:SetFunctionBreakpointsArguments) {
		function doSetFunctionBreakpoints(callback) {
			connection.sendCommand(Protocol.SetFunctionBreakpoints, args.breakpoints, function(error, result) {
				respond(response, error, function() {
					response.body = {breakpoints: [for (bp in result) {verified: true, id: bp.id}]};
					response.success = true;
				});
				if (callback != null)
					callback();
			});
		}
		if (connection == null)
			postLaunchActions.push(cb -> doSetFunctionBreakpoints(cb))
		else
			doSetFunctionBreakpoints(null);
	}

	function doSetBreakpoints(response:SetBreakpointsResponse, args:SetBreakpointsArguments, callback:Null<Void->Void>) {
		var params:SetBreakpointsParams = {
			file: args.source.path,
			breakpoints: [
				for (sbp in args.breakpoints) {
					var bp:{line:Int, ?column:Int, ?condition:String} = {line: sbp.line};
					if (sbp.column != null)
						bp.column = sbp.column;
					if (sbp.condition != null)
						bp.condition = sbp.condition;
					bp;
				}
			]
		}
		connection.sendCommand(Protocol.SetBreakpoints, params, function(error, result) {
			respond(response, error, function() {
				response.body = {breakpoints: [for (bp in result) {verified: true, id: bp.id}]};
				sendResponse(response);
			});
			if (callback != null)
				callback();
		});
	}

	override function evaluateRequest(response:EvaluateResponse, args:EvaluateArguments) {
		// I don't want to have to commit this...
		// if (args.context == "hover") {
		// 	switch (args.expression.charCodeAt(0)) {
		// 		case '"'.code if (!~/[^\\]"/.matchSub(args.expression, 1)):
		// 			args.expression += '"';
		// 		case "'".code if (!~/[^\\]'/.matchSub(args.expression, 1)):
		// 			args.expression += "'";
		// 		case _:
		// 	}
		// }
		stopContext.evaluate(args, function(error, result) {
			respond(response, error, function() {
				response.success = true;
				var ref = if (!result.structured) {
					0;
				} else {
					var v = stopContext.findVar(args.expression);
					v == null ? 0 : v.variablesReference;
				}
				response.body = {
					result: result.value,
					type: result.type,
					variablesReference: ref
				}
			});
		});
	}

	override function setExceptionBreakPointsRequest(response:SetExceptionBreakpointsResponse, args:SetExceptionBreakpointsArguments) {
		connection.sendCommand(Protocol.SetExceptionOptions, args.filters, function(error, result) {});
		sendResponse(response);
	}

	override function configurationDoneRequest(response:ConfigurationDoneResponse, args:ConfigurationDoneArguments) {
		if (!stopOnEntry) {
			continueRequest(cast response, null);
		}
		sendResponse(response);
	}

	override function completionsRequest(response:CompletionsResponse, args:CompletionsArguments) {
		connection.sendCommand(Protocol.GetCompletion, args, function(error, result) {
			respond(response, error, function() {
				response.body = {
					targets: [
						for (item in result) {
							var item2:protocol.debug.Types.CompletionItem = {label: item.label, type: item.type};
							if (item.start != null)
								item2.start = item.start;
							item2;
						}
					]
				}
			});
		});
	}

	function respond<T>(response:Response<T>, error:Null<Message.Error>, f:Void->Void) {
		if (error != null) {
			response.success = false;
			response.message = error.message;
		} else {
			response.success = true;
			f();
		}
		sendResponse(response);
	}

	static function main() {
		adapter.DebugSession.run(Main);
	}
}
