import protocol.debug.Types;

@:keep
class Main extends adapter.DebugSession {
	override function initializeRequest(response:InitializeResponse, args:InitializeRequestArguments) {
		sendResponse(response);
	}

	override function launchRequest(response:LaunchResponse, args:LaunchRequestArguments) {
		trace("launching");
	}

	static function main() {
		adapter.DebugSession.run(Main);
	}
}
