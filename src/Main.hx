import protocol.debug.Types;
import js.node.Net;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess.ChildProcessEvent;
import js.node.net.Socket.SocketEvent;
import Message;

typedef EvalLaunchRequestArguments = {
	>protocol.debug.Types.LaunchRequestArguments,
	var cwd:String;
	var hxml:String;
	var stopOnEntry:Bool;
}

enum VariablesReference {
	Scope(frameId:Int, scopeNumber:Int);

}

class StopContext {
	var connection:Connection;
	var references = new Map<Int,VariablesReference>();
	var nextId = 1;
	var currentFrameId = 0; // current is always the top one at the start

	public function new(connection) {
		this.connection = connection;
	}

	inline function getNextId() return nextId++;

	public function getScopes(frameId:Int, callback:Array<Scope>->Void) {
		if (currentFrameId != frameId) {
			connection.sendCommand("frame", "" + frameId, function(_) {
				currentFrameId = frameId;
				doGetScopes(callback)
			});
		} else {
			doGetScopes(callback);
		}
	}

	function doGetScopes(callback:Array<Scope>->Void) {
		connection.sendCommand("scopes", function(msg:{result:Array<{id:Int, name:String}>}) {
			var scopes:Array<Scope> = [];
			for (scopeInfo in msg.result) {
				scopes.push(cast new adapter.DebugSession.Scope(scopeInfo.name, scopeInfo.id));
			}
			callback(scopes);
		});
	}

	public function getVariables(reference:Int, callback:Array<Variable>->Void) {
		connection.sendCommand("vars", "" + reference, function(msg:{result:Array<{id:Int, name:String}>}) {
			var vars:Array<Variable> = [for (v in msg.result) {name: v.name, value: "", variablesReference: v.id}];
			callback(vars);
		});
	}
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
				"-D", "interp-debugger",
				"-D", 'interp-debugger-socket=127.0.0.1:$port'
			];
			var haxeProcess = ChildProcess.spawn("haxe", args, {stdio: Inherit});
			haxeProcess.on(ChildProcessEvent.Exit, onExit);
		});
	}

	var stopContext:StopContext;

	function onEvent<T>(type:String, data:T) {
		switch (type) {
			case "breakpoint_stop":
				stopContext = new StopContext(connection);
				sendEvent(new adapter.DebugSession.StoppedEvent("breakpoint", 0));
			case "exception_stop":
				stopContext = new StopContext(connection);
				var evt = new adapter.DebugSession.StoppedEvent("exception", 0);
				evt.body.text = (cast data).text;
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

	override function stepInRequest(response:StepInResponse, args:StepInArguments) {
		connection.sendCommand("s");
		sendResponse(response);
		sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
	}

	override function stepOutRequest(response:StepOutResponse, args:StepOutArguments) {
		connection.sendCommand("f");
		sendResponse(response);
		sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
	}


	override function nextRequest(response:NextResponse, args:NextArguments) {
		connection.sendCommand("n");
		sendResponse(response);
		sendEvent(new adapter.DebugSession.StoppedEvent("step", 0));
	}

	override function stackTraceRequest(response:StackTraceResponse, args:StackTraceArguments) {
		connection.sendCommand("w", function(msg:{result:Array<StackFrameInfo>}) {
			var result:Array<StackFrame> = [
				for (info in msg.result)
					{
						id: info.id,
						name: info.name,
						source: {path: info.source},
						line: info.line,
						column: info.column,
						endLine: info.endLine,
						endColumn: info.endColumn
					}
			];
			result.reverse();
			response.body = {
				stackFrames: result
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
		connection.sendCommand("c");
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
				var arg = args.source.path + ":" + bp.line;
				if (bp.column != null)
					arg += ":" + (bp.column - 1);
				connection.sendCommand("b", arg, function(msg:{?result:Int, ?error:String}) {
					if (msg.result != null) {
						verifiedIds.push(msg.result);
						cb({verified: true, id: msg.result});
					} else {
						cb({verified: false, message: msg.error});
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
				connection.sendCommand("d", "" + id, _ -> cb(null));
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

typedef StackFrameInfo = {
	var id:Int;
	var name:String;
	var source:String;
	var line:Int;
	var column:Int;
	var endLine:Int;
	var endColumn:Int;
}
