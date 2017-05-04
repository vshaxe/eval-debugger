import protocol.debug.Types;
import js.node.Net;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess.ChildProcessEvent;
import Message;

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
		var hxmlFile:String = (cast args).hxml;
		var cwd:String = (cast args).cwd;

		function onConnected(socket) {
			trace("Haxe connected!");
			connection = new Connection(socket);

			connection.onEvent = onEvent;

			for (action in postLaunchActions)
				action();
			postLaunchActions = [];

			sendResponse(response);
			sendEvent(new adapter.DebugSession.StoppedEvent("entry", 0));
		}

		function onExit(_, _) {
			trace("Haxe exited!");
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

	function onEvent<T>(type:String, data:T) {
		switch (type) {
			case "breakpoint_stop":
				sendEvent(new adapter.DebugSession.StoppedEvent("breakpoint", 0));
		}
	}

	override function stackTraceRequest(response:StackTraceResponse, args:StackTraceArguments) {
		connection.sendCommand("w", function(msg:{result:Array<StackFrameInfo>}) {
			response.body = {
				stackFrames: [
					for (info in msg.result)
						({
							id: info.id,
							name: info.name,
							source: {path: info.source},
							line: info.line,
							column: info.column,
							endLine: info.endLine,
							endColumn: info.endColumn
						} : StackFrame)
				]
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
