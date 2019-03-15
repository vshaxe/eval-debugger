import protocol.debug.Types;
import js.Promise;
import js.node.ChildProcess.ChildProcessSpawnOptions;

typedef ILocation = {
	var path:String;
	var line:Int;
	var ?column:Int;
	var ?verified:Bool;
}

typedef IPartialLocation = {
	var ?path:String;
	var ?line:Int;
	var ?column:Int;
	var ?verified:Bool;
}

@:jsRequire("vscode-debugadapter-testsupport", "DebugClient")
extern class DebugClient {
	var defaultTimeout:Int;
	function new(runtime:String, executable:String, debugType:String, ?spawnOptions:ChildProcessSpawnOptions, ?enableStderr:Bool):Void;
	function start(?port:Int):Promise<Void>;
	function stop():Promise<Void>;
	function stopAdapter():Void;
	// protocol
	function initializeRequest(?args:InitializeRequestArguments):Promise<InitializeResponse>;
	function configurationDoneRequest(?args:ConfigurationDoneArguments):Promise<ConfigurationDoneResponse>;
	function launchRequest(args:LaunchRequestArguments):Promise<LaunchResponse>;
	function attachRequest(args:AttachRequestArguments):Promise<AttachResponse>;
	function restartRequest(args:RestartArguments):Promise<RestartResponse>;
	// function terminateRequest(?args:TerminateArguments):Promise<TerminateResponse>;
	function disconnectRequest(?args:DisconnectArguments):Promise<DisconnectResponse>;
	function setBreakpointsRequest(args:SetBreakpointsArguments):Promise<SetBreakpointsResponse>;
	function setFunctionBreakpointsRequest(args:SetFunctionBreakpointsArguments):Promise<SetFunctionBreakpointsResponse>;
	function setExceptionBreakpointsRequest(args:SetExceptionBreakpointsArguments):Promise<SetExceptionBreakpointsResponse>;
	function continueRequest(args:ContinueArguments):Promise<ContinueResponse>;
	function nextRequest(args:NextArguments):Promise<NextResponse>;
	function stepInRequest(args:StepInArguments):Promise<StepInResponse>;
	function stepOutRequest(args:StepOutArguments):Promise<StepOutResponse>;
	function stepBackRequest(args:StepBackArguments):Promise<StepBackResponse>;
	// function reverseContinueRequest(args:ReverseContinueArguments):Promise<ReverseContinueResponse>;
	function restartFrameRequest(args:RestartFrameArguments):Promise<RestartFrameResponse>;
	function gotoRequest(args:GotoArguments):Promise<GotoResponse>;
	function pauseRequest(args:PauseArguments):Promise<PauseResponse>;
	function stackTraceRequest(args:StackTraceArguments):Promise<StackTraceResponse>;
	function scopesRequest(args:ScopesArguments):Promise<ScopesResponse>;
	function variablesRequest(args:VariablesArguments):Promise<VariablesResponse>;
	function setVariableRequest(args:SetVariableArguments):Promise<SetVariableResponse>;
	function sourceRequest(args:SourceArguments):Promise<SourceResponse>;
	function threadsRequest():Promise<ThreadsResponse>;
	function modulesRequest(args:ModulesArguments):Promise<ModulesResponse>;
	function evaluateRequest(args:EvaluateArguments):Promise<EvaluateResponse>;
	function stepInTargetsRequest(args:StepInTargetsArguments):Promise<StepInTargetsResponse>;
	function gotoTargetsRequest(args:GotoTargetsArguments):Promise<GotoTargetsResponse>;
	function completionsRequest(args:CompletionsArguments):Promise<CompletionsResponse>;
	function exceptionInfoRequest(args:ExceptionInfoArguments):Promise<ExceptionInfoResponse>;
	function customRequest(command:String, ?args:Dynamic):Promise<Response<Dynamic>>;
	// convenience
	function waitForEvent(eventType:String, ?timeout:Float):Promise<Event<Dynamic>>;
	function configurationSequence():Promise<Dynamic>;
	function launch(launchArgs:Dynamic):Promise<LaunchResponse>;
	function configurationDone():Promise<Response<Dynamic>>;
	function assertStoppedLocation(reason:String, expected:{
		?path:Dynamic,
		?line:Int,
		?column:Int
	}):Promise<StackTraceResponse>;
	function assertPartialLocationsEqual(locA:IPartialLocation, locB:IPartialLocation):Void;
	function assertOutput(category:String, expected:String, ?timeout:Int):Promise<Event<Dynamic>>;
	function assertPath(path:String, expected:String, ?message:String):Void;
	function hitBreakpoint(launchArgs:Dynamic, location:ILocation, ?expectedStopLocation:IPartialLocation,
		?expectedBPLocation:IPartialLocation):Promise<Dynamic>;
}

// TODO: don't copy that here
typedef DebugConfiguration = {
	/**
	 * The type of the debug session.
	 */
	var type:String;

	/**
	 * The name of the debug session.
	 */
	var name:String;

	/**
	 * The request type of the debug session.
	 */
	var request:String;
}

/**
	Configuration for the Haxe executable.
**/
typedef HaxeExecutableConfiguration = {
	/**
		Absolute path to the Haxe executable, or a command / alias like `"haxe"`.
		Use `isCommand` to check.
	**/
	var executable(default, never):String;

	/**
		Whether `executable` is a command (`true`) or an absolute path (`false`).
	**/
	var isCommand(default, never):Bool;

	/**
		Additional environment variables used for running Haxe executable.
	**/
	var env(default, never):haxe.DynamicAccess<String>;
}

typedef EvalLaunchDebugConfiguration = DebugConfiguration & {
	var ?cwd:String;
	var ?args:Array<String>;
	var stopOnEntry:Bool;
	var haxeExecutable:HaxeExecutableConfiguration;
	var mergeScopes:Bool;
	var showGeneratedVariables:Bool;
}

class TestEvalDebugger {
	static function main() {
		var dc = new DebugClient("node", "./adapter.js", "haxe-eval");
		dc.defaultTimeout = 1000;
		Promise.all([
			dc.start(),
			dc.configurationSequence(),
			dc.launch(getConfig()),
			dc.waitForEvent("terminated"),
			dc.stop()
		]);
	}

	static function getConfig():EvalLaunchDebugConfiguration {
		return {
			type: "haxe-eval",
			name: "Haxe Interpreter",
			request: "launch",
			stopOnEntry: false,
			haxeExecutable: {
				executable: "haxe",
				isCommand: false,
				env: {}
			},
			mergeScopes: false,
			showGeneratedVariables: false
		}
	}
}
