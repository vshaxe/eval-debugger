import js.node.stream.Readable.ReadableEvent;
import js.node.net.Socket;
import js.node.Buffer;

class Connection {
	var socket:Socket;
	var buffer:Buffer;
	var index:Int;
	var nextMessageLength:Int;
	var callbacks:Array<Null<Message.Error>->Null<Dynamic>->Void>;

	static inline var DEFAULT_BUFFER_SIZE = 4096;

	public function new(socket) {
		this.socket = socket;
		buffer = new Buffer(DEFAULT_BUFFER_SIZE);
		index = 0;
		nextMessageLength = -1;
		callbacks = [];
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
			nextMessageLength = -1;
			var json = haxe.Json.parse(bytes);
			onMessage(json);
		}
	}

	public dynamic function onEvent<T>(type:String, data:T) {}

	function onMessage<T>(msg:Message) {
		trace('GOT MESSAGE ${haxe.Json.stringify(msg)}');
		if (msg.id == null) {
			onEvent(msg.method, msg.params);
		} else {
			var callback = callbacks.shift();
			if (callback != null) {
				callback(msg.error, msg.result);
			}
		}
	}

	public function sendCommand<T:{}>(name:String, ?params:{}, ?callback:Null<Message.Error>->Null<T>->Void) {
		var cmd = haxe.Json.stringify({
			id: 0,
			method: name,
			params: params
		});
		trace('Sending command: $cmd');
		var body = Buffer.from(cmd, "utf-8");
		var header = Buffer.alloc(2);
		header.writeUInt16LE(body.length, 0);
		socket.write(header);
		socket.write(body);
		if (callback != null)
			callbacks.push(callback);
	}
}
