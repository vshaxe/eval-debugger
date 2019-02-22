import haxe.DynamicAccess;
import protocol.debug.Types;
import js.node.Buffer;
import js.node.Net;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess.ChildProcessEvent;
import js.node.net.Socket.SocketEvent;
import js.node.stream.Readable.ReadableEvent;
import Protocol;

using Lambda;
using StringTools;

typedef EvalLaunchRequestArguments = protocol.debug.Types.LaunchRequestArguments & {
	var cwd:String;
	var args:Array<String>;
	var stopOnEntry:Bool;
	var haxeExecutable:{
		var executable:String;
		var env:DynamicAccess<String>;
	};
	var mergeScopes:Bool;
}

@:keep
class Main extends adapter.DebugSession {
	function traceToOutput(value:Dynamic, ?infos:haxe.PosInfos) {
		var msg = Std.string(value);
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
	var launchArgs:EvalLaunchRequestArguments;

	function executePostLaunchActions(callback) {
		function loop() {
			var action = postLaunchActions.shift();
			if (action == null)
				return callback();
			action(loop);
		}
		loop();
	}

	function exit() {
		sendEvent(new adapter.DebugSession.TerminatedEvent(false));
	}

	function checkHaxeVersion(response:LaunchResponse, haxe:String, env:DynamicAccess<String>) {
		function error(message:String) {
			sendErrorResponse(cast response, 3000, message);
			exit();
			return false;
		}

		var versionCheck = ChildProcess.spawnSync(haxe, ["-version"], {env: env});
		var output = (versionCheck.stderr : Buffer).toString().trim();
		if (output == "")
			output = (versionCheck.stdout : Buffer).toString().trim(); // haxe 4.0 prints -version output to stdout instead

		if (versionCheck.status != 0)
			return error("Haxe version check failed: " + output);

		var majorVersion = Std.parseInt(output.split(".")[0]);
		if (majorVersion < 4)
			return error('eval-debugger requires Haxe 4 or newer, found $output');

		return true;
	}

	override function launchRequest(response:LaunchResponse, args:LaunchRequestArguments) {
		var args:EvalLaunchRequestArguments = cast args;
		launchArgs = args;
		var haxeArgs = args.args;
		var cwd = args.cwd;

		var haxe = args.haxeExecutable.executable;

		var env = new haxe.DynamicAccess();
		for (key in js.Node.process.env.keys())
			env[key] = js.Node.process.env[key];
		for (key in args.haxeExecutable.env.keys())
			env[key] = args.haxeExecutable.env[key];

		if (!checkHaxeVersion(response, haxe, env)) {
			return;
		}

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

		var server = Net.createServer(onConnected);
		server.listen(0, function() {
			var port = server.address().port;
			var haxeArgs = ["--cwd", cwd, "-D", 'eval-debugger=127.0.0.1:$port'].concat(haxeArgs);
			var haxeProcess = ChildProcess.spawn(haxe, haxeArgs, {stdio: Pipe, env: env});
			haxeProcess.stdout.on(ReadableEvent.Data, onStdout);
			haxeProcess.stderr.on(ReadableEvent.Data, onStderr);
			haxeProcess.on(ChildProcessEvent.Exit, (_, _) -> exit());
		});
	}

	function onStdout(data:Buffer) {
		sendEvent(new adapter.DebugSession.OutputEvent(data.toString("utf-8"), stdout));
	}

	function onStderr(data:Buffer) {
		sendEvent(new adapter.DebugSession.OutputEvent(data.toString("utf-8"), stderr));
	}

	function onEvent<P>(type:NotificationMethod<P>, data:P) {
		switch (type) {
			case Protocol.BreakpointStop:
				sendEvent(new adapter.DebugSession.StoppedEvent("breakpoint", 0));
			case Protocol.ExceptionStop:
				var evt = new adapter.DebugSession.StoppedEvent("exception", 0);
				evt.body.text = data.text;
				sendEvent(evt);
		}
	}

	var varReferenceMapping:Map<Int, Array<Int>>;

	function mergeScopes(scopes:Array<Scope>) {
		varReferenceMapping = [];
		var mergedScopes = new Map<String, Scope>();
		for (scope in scopes) {
			var merged = mergedScopes[scope.name];
			if (merged == null)
				merged = scope;
			else {
				if (scope.line < merged.line)
					merged.line = scope.line;
				if (scope.column < merged.line)
					merged.column = scope.line;
				if (scope.endLine > merged.endLine)
					merged.endLine = scope.endLine;
				if (scope.endColumn > merged.endColumn)
					merged.endColumn = scope.endColumn;
			}
			mergedScopes[merged.name] = merged;

			var mergedRef = merged.variablesReference;
			var mapping = varReferenceMapping[mergedRef];
			if (mapping == null)
				mapping = [];
			mapping.push(scope.variablesReference);
			varReferenceMapping[mergedRef] = mapping;
		}
		return mergedScopes.array();
	}

	function varInfoToVariable(varInfo:VarInfo):Variable {
		return {
			name: varInfo.name,
			value: varInfo.value,
			type: varInfo.type,
			variablesReference: varInfo.id,
			namedVariables: varInfo.numChildren
		};
	}

	override function scopesRequest(response:ScopesResponse, args:ScopesArguments) {
		connection.sendCommand(Protocol.GetScopes, {frameId: args.frameId}, function(error, result) {
			var scopes:Array<Scope> = [];
			for (scopeInfo in result) {
				var scope:Scope = cast new adapter.DebugSession.Scope(scopeInfo.name, scopeInfo.id);
				if (scopeInfo.pos != null) {
					var p = scopeInfo.pos;
					scope.source = {path: p.source};
					scope.line = p.line;
					scope.column = p.column;
					scope.endLine = p.endLine;
					scope.endColumn = p.endColumn;
				}
				scopes.push(scope);
			}
			// if (launchArgs.mergeScopes) {
			// 	scopes = mergeScopes(scopes);
			// }
			response.body = {scopes: scopes};
			sendResponse(response);
		});
	}

	override function variablesRequest(response:VariablesResponse, args:VariablesArguments) {
		// var scopes = [args.variablesReference];
		// // if (launchArgs.mergeScopes && varReferenceMapping.exists(args.variablesReference))
		// // 	scopes = varReferenceMapping[args.variablesReference].copy();

		// var mergedVars = [];
		// function requestVars() {
		// 	stopContext.getVariables(scopes.shift(), vars -> {
		// 		mergedVars = mergedVars.concat(vars);
		// 		if (scopes.length > 0) {
		// 			requestVars();
		// 		} else {
		// 			response.body = {variables: mergedVars};
		// 			sendResponse(response);
		// 		}
		// 	});
		// }
		// requestVars();
		connection.sendCommand(Protocol.GetScopeVariables, {id: args.variablesReference}, function(error, result) {
			var r = [];
			for (varInfo in result) {
				r.push(varInfoToVariable(varInfo));
			}
			response.body = {variables: r};
			sendResponse(response);
		});
	}

	override function setVariableRequest(response:SetVariableResponse, args:SetVariableArguments) {
		connection.sendCommand(Protocol.SetVariable, {
			id: args.variablesReference,
			name: args.name,
			value: args.value
		}, function(error, result) {
			response.body = {
				variablesReference: result.id,
				type: result.type,
				value: result.value,
				namedVariables: result.numChildren
			};
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
		connection.sendCommand(Protocol.Evaluate, {expr: args.expression, frameId: args.frameId}, function(error, result) {
			response.body = {
				result: result.value,
				variablesReference: result.id,
				type: result.type,
				namedVariables: result.numChildren
			}
			sendResponse(response);
		});
	}

	override function setExceptionBreakPointsRequest(response:SetExceptionBreakpointsResponse, args:SetExceptionBreakpointsArguments) {
		connection.sendCommand(Protocol.SetExceptionOptions, args.filters, function(error, result) {});
		sendResponse(response);
	}

	override function configurationDoneRequest(response:ConfigurationDoneResponse, args:ConfigurationDoneArguments) {
		if (!launchArgs.stopOnEntry) {
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
