import protocol.debug.Types;
import js.node.Net;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess.ChildProcessEvent;
import js.node.net.Socket.SocketEvent;
import Protocol;

typedef EvalLaunchRequestArguments = {
	>protocol.debug.Types.LaunchRequestArguments,
	var cwd:String;
	var hxml:String;
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

	function new() {
		super();
		setDebuggerColumnsStartAt1(false);
	}

	override function initializeRequest(response:InitializeResponse, args:InitializeRequestArguments) {
		// haxe.Log.trace = traceToOutput;
		sendEvent(new adapter.DebugSession.InitializedEvent());
		response.body.supportsSetVariable = true;
		sendResponse(response);
		postLaunchActions = [];
		breakpoints = new Map();
	}

	var connection:Connection;
	var breakpoints:Map<String,Array<Int>>;
	var postLaunchActions:Array<Void->Void>;

	override function launchRequest(response:LaunchResponse, args:LaunchRequestArguments) {
		var args:EvalLaunchRequestArguments = cast args;
		var hxmlFile = args.hxml;
		var cwd = args.cwd;

		function onConnected(socket) {
			trace("Haxe connected!");
			connection = new Connection(socket);
			connection.onEvent = onEvent;

			socket.on(SocketEvent.Error, error -> trace('Socket error: $error'));

			for (action in postLaunchActions)
				action();
			postLaunchActions = [];

			if (args.stopOnEntry) {
				sendResponse(response);
				sendEvent(new adapter.DebugSession.StoppedEvent("entry", 0));
			} else {
				continueRequest(cast response, null);
			}
		}

		function onExit(_, _) {
			sendEvent(new adapter.DebugSession.TerminatedEvent(false));
		}

		var server = Net.createServer(onConnected);
		server.listen(0, function() {
			var port = server.address().port;
			var args = [
				"--cwd", cwd,
				hxmlFile,
				"-D", 'eval-debugger=127.0.0.1:$port',
			];
			var haxeProcess = ChildProcess.spawn("haxe", args, {stdio: Inherit});
			haxeProcess.on(ChildProcessEvent.Exit, onExit);
		});
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
		connection.sendCommand(Protocol.StepIn, {});
		sendResponse(response);
		sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
	}

	override function stepOutRequest(response:StepOutResponse, args:StepOutArguments) {
		connection.sendCommand(Protocol.StepOut, {});
		sendResponse(response);
		sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
	}


	override function nextRequest(response:NextResponse, args:NextArguments) {
		connection.sendCommand(Protocol.Next, {});
		sendResponse(response);
		sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
	}

	override function stackTraceRequest(response:StackTraceResponse, args:StackTraceArguments) {
		connection.sendCommand(Protocol.StackTrace, {}, function(error, result) {
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
			sendResponse(response);
		});
	}

	override function threadsRequest(response:ThreadsResponse) {
		// TODO: support other threads?
		response.body = {threads: [{id: 0, name: "Interp"}]};
		sendResponse(response);
	}

	override function continueRequest(response:ContinueResponse, args:ContinueArguments) {
		connection.sendCommand(Protocol.Continue, {});
		sendResponse(response);
	}

	override function setBreakPointsRequest(response:SetBreakpointsResponse, args:SetBreakpointsArguments) {
		if (connection == null)
			postLaunchActions.push(doSetBreakpoints.bind(response, args));
		else
			doSetBreakpoints(response, args);
	}

	function doSetBreakpoints(response:SetBreakpointsResponse, args:SetBreakpointsArguments) {
		function sendBreakpoints() {
			if (args.breakpoints.length == 0)
				return sendResponse(response);

			var verifiedIds = new Array<Int>();
			function sendBreakpoint(bp:SourceBreakpoint, cb:Breakpoint->Void) {
				var arg:{file:String, line:Int, ?column:Int} = {file: args.source.path, line: bp.line};
				if (bp.column != null)
					arg.column = bp.column - 1;
				connection.sendCommand(Protocol.SetBreakpoint, arg, function(error, result) {
					if (error == null) {
						verifiedIds.push(result.id);
						cb({verified: true, id: result.id});
					} else {
						cb({verified: false, message: error.message});
					}
				});
			}
			asyncMap(args.breakpoints, sendBreakpoint, function(result) {
				breakpoints.set(args.source.path, verifiedIds);
				response.body = {breakpoints: result};
				sendResponse(response);
			});
		}

		var currentVerifiedIds = breakpoints[args.source.path];
		if (currentVerifiedIds == null) {
			sendBreakpoints();
			return;
		} else {
			function clearBreakpoint(id:Int, cb:Any->Void) {
				connection.sendCommand(Protocol.RemoveBreakpoint, {id: id}, (_,_) -> cb(null));
			}
			asyncMap(currentVerifiedIds, clearBreakpoint, function(_) {
				breakpoints.remove(args.source.path);
				sendBreakpoints();
			});
		}

	}

	static function asyncMap<T,T2>(args:Array<T>, fn:T->(T2->Void)->Void, cb:Array<T2>->Void) {
		var result = [];
		function loop() {
			if (args.length == 0)
				return cb(result);
			var arg = args.shift();
			fn(arg, function(v) {
				result.push(v);
				loop();
			});
		}
		loop();
	}

	static function main() {
		adapter.DebugSession.run(Main);
	}
}
