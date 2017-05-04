import protocol.debug.Types;
import js.node.Buffer;
import js.node.Net;
import js.node.stream.Readable;
import js.node.net.Socket;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess.ChildProcessEvent;

typedef Message = {}

class Connection {
	var socket:Socket;
	var buffer:Buffer;
	var index:Int;
	var nextMessageLength:Int;

	static inline var DEFAULT_BUFFER_SIZE = 4096;

	public function new(socket) {
		this.socket = socket;
		buffer = new Buffer(DEFAULT_BUFFER_SIZE);
		index = 0;
		nextMessageLength = -1;
		socket.on(ReadableEvent.Data, onData);
	}

	function append(data:Buffer) {
		// append received data to the buffer, increasing it if needed
		if (buffer.length - index >= data.length) {
			data.copy(buffer, index, 0, data.length);
		} else {
			var newSize = (Math.ceil((index + data.length) / DEFAULT_BUFFER_SIZE) + 1) * DEFAULT_BUFFER_SIZE; // copied from the language-server protocol reader
			if (index == 0) {
				buffer = new Buffer(newSize);
				data.copy(buffer, 0, 0, data.length);
			} else {
				buffer = Buffer.concat([buffer.slice(0, index), data], newSize);
			}
		}
		index += data.length;
	}

	function onData(data:Buffer) {
		trace(data.toString());
		append(data);
		while (true) {
			if (nextMessageLength == -1) {
				if (index < 2)
					return; // not enough data
				nextMessageLength = buffer.readUInt16LE(0);
				index -= 2;
				buffer.copy(buffer, 0, 2);
			}
			if (index < nextMessageLength)
				return;
			var bytes = buffer.toString("utf-8", 0, nextMessageLength);
			buffer.copy(buffer, 0, nextMessageLength);
			index -= nextMessageLength;
			var json = haxe.Json.parse(bytes);
			onMessage(json);
		}
	}

	public dynamic function onMessage(msg:Message) {}

	public function sendCommand(name:String, ?arg:String) {
		var cmd = if (arg == null) name else name + " " + arg;
		var body = Buffer.from(cmd, "utf-8");
		var header = Buffer.alloc(2);
		header.writeUInt16LE(body.length, 0);
		socket.write(header);
		socket.write(body);
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

	override function initializeRequest(response:InitializeResponse, args:InitializeRequestArguments) {
		// haxe.Log.trace = traceToOutput;
		sendResponse(response);
	}

	override function launchRequest(response:LaunchResponse, args:LaunchRequestArguments) {
		var hxmlFile:String = (cast args).hxml;
		var cwd:String = (cast args).cwd;

		function onMessage(msg:Message) {
			trace('Got message: $msg');
		}

		function onConnected(socket) {
			trace("Haxe connected!");
			var connection = new Connection(socket);
			connection.onMessage = onMessage;
			connection.sendCommand("files");
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
			sendResponse(response);
		});
	}

	static function main() {
		adapter.DebugSession.run(Main);
	}
}
