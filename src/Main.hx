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

	override function initializeRequest(response:InitializeResponse, args:InitializeRequestArguments) {
		// haxe.Log.trace = traceToOutput;
		sendEvent(new adapter.DebugSession.InitializedEvent());
		sendResponse(response);
		postLaunchActions = [];
	}

	var connection:Connection;
	var postLaunchActions:Array<Void->Void>;

	override function launchRequest(response:LaunchResponse, args:LaunchRequestArguments) {
		var hxmlFile:String = (cast args).hxml;
		var cwd:String = (cast args).cwd;

		function onConnected(socket) {
			trace("Haxe connected!");
			connection = new Connection(socket);

			for (action in postLaunchActions)
				action();

			sendResponse(response);
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

	override function setBreakPointsRequest(response:SetBreakpointsResponse, args:SetBreakpointsArguments) {
		trace("Setting breakpoints " + args);

		if (connection == null)
			postLaunchActions.push(doSetBreakpoints.bind(response, args));
		else
			doSetBreakpoints(response, args);
	}

	function doSetBreakpoints(response:SetBreakpointsResponse, args:SetBreakpointsArguments) {
		for (bp in args.breakpoints) {
			var arg = args.source.path + ":" + bp.line;
			connection.sendCommand("b", arg, function(msg) {
				trace(msg);
			});
		}
		sendResponse(response);
	}

	static function main() {
		adapter.DebugSession.run(Main);
	}
}
