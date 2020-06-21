import Protocol;
import haxe.DynamicAccess;
import js.node.Buffer;
import js.node.ChildProcess;
import js.node.Net;
import js.node.child_process.ChildProcess.ChildProcessEvent;
import js.node.net.Socket.SocketEvent;
import js.node.stream.Readable.ReadableEvent;
import vscode.debugProtocol.DebugProtocol;

using Lambda;
using StringTools;

typedef EvalLaunchRequestArguments = LaunchRequestArguments & {
	final cwd:String;
	final args:Array<String>;
	final stopOnEntry:Bool;
	final haxeExecutable:{
		final executable:String;
		final env:DynamicAccess<String>;
	};
	final mergeScopes:Bool;
	final showGeneratedVariables:Bool;
}

@:keep
class Main extends vscode.debugAdapter.DebugSession {
	final threads:Map<Int, Bool>;

	public function new() {
		super();
		threads = new Map();
	}

	function traceToOutput(value:Dynamic, ?infos:haxe.PosInfos) {
		var msg = Std.string(value);
		if (infos != null && infos.customParams != null) {
			msg += " " + infos.customParams.join(" ");
		}
		msg += "\n";
		sendEvent(new vscode.debugAdapter.DebugSession.OutputEvent(msg));
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
	var postLaunchActions:Array<(() -> Void)->Void>;
	var launchArgs:EvalLaunchRequestArguments;

	function executePostLaunchActions(callback) {
		function loop() {
			final action = postLaunchActions.shift();
			if (action == null)
				return callback();
			action(loop);
		}
		loop();
	}

	function exit() {
		sendEvent(new vscode.debugAdapter.DebugSession.TerminatedEvent(false));
	}

	function checkHaxeVersion(response:LaunchResponse, haxe:String, env:DynamicAccess<String>, cwd:String) {
		function error(message:String) {
			sendErrorResponse(cast response, 3000, message);
			exit();
			return false;
		}

		final versionCheck = ChildProcess.spawnSync(haxe, ["-version"], {env: env, cwd: cwd});
		var output = (versionCheck.stderr : Buffer).toString().trim();
		if (output == "")
			output = (versionCheck.stdout : Buffer).toString().trim(); // haxe 4.0 prints -version output to stdout instead

		if (versionCheck.status != 0)
			return error("Haxe version check failed: " + output);

		final parts = ~/[\.\-+]/g.split(output);
		final majorVersion = Std.parseInt(parts[0]);
		if (majorVersion < 4)
			return error('eval-debugger requires Haxe 4.0.0 or newer, found $output');

		return true;
	}

	override function launchRequest(response:LaunchResponse, args:LaunchRequestArguments) {
		final args:EvalLaunchRequestArguments = cast args;
		launchArgs = args;
		final haxeArgs = args.args;
		final cwd = args.cwd;

		final haxe = args.haxeExecutable.executable;

		final env = new haxe.DynamicAccess();
		for (key in js.Node.process.env.keys())
			env[key] = js.Node.process.env[key];
		for (key in args.haxeExecutable.env.keys())
			env[key] = args.haxeExecutable.env[key];

		if (!checkHaxeVersion(response, haxe, env, cwd)) {
			return;
		}

		function onConnected(socket) {
			trace("Haxe connected!");
			connection = new Connection(socket);
			connection.onEvent = onEvent;

			socket.on(SocketEvent.Error, error -> trace('Socket error: $error'));

			function ready() {
				sendEvent(new vscode.debugAdapter.DebugSession.InitializedEvent());
			}

			executePostLaunchActions(function() {
				if (args.stopOnEntry) {
					ready();
					sendResponse(response);
					sendEvent(new vscode.debugAdapter.DebugSession.StoppedEvent("entry", 0));
				} else {
					ready();
				}
			});
		}

		final server = Net.createServer(onConnected);
		server.listen(0, function() {
			final port = server.address().port;
			final haxeArgs = ["--cwd", cwd, "-D", 'eval-debugger=127.0.0.1:$port'].concat(haxeArgs);
			final haxeProcess = ChildProcess.spawn(haxe, haxeArgs, {stdio: Pipe, env: env, cwd: cwd});
			haxeProcess.stdout.on(ReadableEvent.Data, onStdout);
			haxeProcess.stderr.on(ReadableEvent.Data, onStderr);
			haxeProcess.on(ChildProcessEvent.Exit, (_, _) -> exit());
		});
	}

	function onStdout(data:Buffer) {
		sendEvent(new vscode.debugAdapter.DebugSession.OutputEvent(data.toString("utf-8"), Stdout));
	}

	function onStderr(data:Buffer) {
		sendEvent(new vscode.debugAdapter.DebugSession.OutputEvent(data.toString("utf-8"), Stderr));
	}

	function onEvent<P>(type:NotificationMethod<P>, data:P) {
		switch type {
			case Protocol.BreakpointStop:
				sendEvent(new vscode.debugAdapter.DebugSession.StoppedEvent("breakpoint", data.threadId));
			case Protocol.ExceptionStop:
				final evt = new vscode.debugAdapter.DebugSession.StoppedEvent("exception", data.threadId);
				evt.body.text = data.text;
				sendEvent(evt);
			case Protocol.ThreadEvent:
				threads[data.threadId] = data.reason != "exited";
				sendEvent(new vscode.debugAdapter.DebugSession.ThreadEvent(data.reason, data.threadId));
		}
	}

	override function disconnectRequest(response:DisconnectResponse, args:DisconnectArguments) {
		for (id => alive in threads) {
			if (alive) {
				sendEvent(new vscode.debugAdapter.DebugSession.ThreadEvent("exited", id));
			}
		}
		sendResponse(response);
	}

	var varReferenceMapping:Map<Int, Array<{id:Int, vars:Array<String>}>>;

	function mergeScopes(scopes:Array<Scope>) {
		varReferenceMapping = [];
		final mergedScopes = new Map<String, Scope>();
		for (scope in scopes) {
			var merged = mergedScopes[scope.name];
			if (merged == null) {
				merged = scope;
			} else {
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

			final mergedRef = merged.variablesReference;
			var mapping = varReferenceMapping[mergedRef];
			if (mapping == null)
				mapping = [];
			mapping.push({id: scope.variablesReference, vars: []});
			varReferenceMapping[mergedRef] = mapping;
		}
		return mergedScopes.array();
	}

	override function scopesRequest(response:ScopesResponse, args:ScopesArguments) {
		connection.sendCommand(Protocol.GetScopes, {frameId: args.frameId}, function(error, result) {
			respond(response, error, function() {
				var scopes:Array<Scope> = [];
				for (scopeInfo in result) {
					final scope:Scope = cast new vscode.debugAdapter.DebugSession.Scope(scopeInfo.name, scopeInfo.id);
					if (scopeInfo.pos != null) {
						final p = scopeInfo.pos;
						scope.source = {path: p.source};
						scope.line = p.line;
						scope.column = p.column;
						scope.endLine = p.endLine;
						scope.endColumn = p.endColumn;
					}
					scopes.push(scope);
				}
				if (launchArgs.mergeScopes) {
					scopes = mergeScopes(scopes);
				}
				response.body = {scopes: scopes};
			});
		});
	}

	override function variablesRequest(response:VariablesResponse, args:VariablesArguments) {
		var scopes = [{id: args.variablesReference, vars: []}];
		if (launchArgs.mergeScopes && varReferenceMapping.exists(args.variablesReference))
			scopes = varReferenceMapping[args.variablesReference].copy();

		final mergedVars = [];
		final names:Map<String, Int> = [];

		function getDisplayName(varInfo:VarInfo) {
			final name = varInfo.name;
			if (names.exists(name)) {
				return '${name} - line ${varInfo.line}';
			} else {
				names[name] = 0;
				return name;
			}
		}
		function requestVars() {
			final scope = scopes.shift();
			connection.sendCommand(Protocol.GetVariables, {id: scope.id}, function(error, result) {
				for (varInfo in result) {
					if (varInfo.generated && !launchArgs.showGeneratedVariables) {
						continue;
					}
					final displayName = getDisplayName(varInfo);
					scope.vars.push(displayName);
					final v = {
						name: displayName,
						value: varInfo.value,
						type: varInfo.type,
						variablesReference: varInfo.id,
						namedVariables: varInfo.numChildren,
						evaluateName: varInfo.name
					};
					mergedVars.push(v);
				}
				if (scopes.length > 0) {
					requestVars();
				} else {
					response.body = {variables: mergedVars};
					sendResponse(response);
				}
			});
		}
		requestVars();
	}

	override function setVariableRequest(response:SetVariableResponse, args:SetVariableArguments) {
		var realRef = args.variablesReference;
		function getRealName() {
			final index = args.name.indexOf(" ");
			if (index == -1) {
				return args.name;
			}
			return args.name.substr(0, index);
		}
		if (launchArgs.mergeScopes) {
			function getRealRef() {
				for (scope in varReferenceMapping[realRef]) {
					for (name in scope.vars) {
						if (name == args.name) {
							return scope.id;
						}
					}
				}
				return realRef;
			}
			realRef = getRealRef();
		}
		connection.sendCommand(Protocol.SetVariable, {
			id: realRef,
			name: getRealName(),
			value: args.value
		}, function(error, result) {
			respond(response, error, function() {
				response.body = {
					variablesReference: result.id,
					type: result.type,
					value: result.value,
					namedVariables: result.numChildren
				};
			});
		});
	}

	override function pauseRequest(response:PauseResponse, args:PauseArguments) {
		connection.sendCommand(Protocol.Pause, {threadId: args.threadId}, function(error, _) {
			respond(response, error, function() {});
			sendEvent(new vscode.debugAdapter.DebugSession.StoppedEvent("paused", args.threadId));
		});
	}

	override function stepInRequest(response:StepInResponse, args:StepInArguments) {
		connection.sendCommand(Protocol.StepIn, {threadId: args.threadId}, function(error, _) {
			respond(response, error, function() {});
			sendEvent(new vscode.debugAdapter.DebugSession.StoppedEvent("step", args.threadId));
		});
	}

	override function stepOutRequest(response:StepOutResponse, args:StepOutArguments) {
		connection.sendCommand(Protocol.StepOut, {threadId: args.threadId}, function(error, _) {
			respond(response, error, function() {});
			sendEvent(new vscode.debugAdapter.DebugSession.StoppedEvent("step", args.threadId));
		});
	}

	override function nextRequest(response:NextResponse, args:NextArguments) {
		connection.sendCommand(Protocol.Next, {threadId: args.threadId}, function(error, _) {
			respond(response, error, function() {});
			sendEvent(new vscode.debugAdapter.DebugSession.StoppedEvent("step", args.threadId));
		});
	}

	override function stackTraceRequest(response:StackTraceResponse, args:StackTraceArguments) {
		connection.sendCommand(Protocol.StackTrace, {threadId: args.threadId}, function(error, result) {
			respond(response, error, function() {
				final r:Array<StackFrame> = [];
				for (info in result) {
					r.push({
						id: info.id,
						name: info.name == "?" ? "Internal" : info.name,
						source: (info.source == null || info.name == "?") ? null : {path: info.source},
						line: info.line,
						column: info.column,
						endLine: info.endLine,
						endColumn: info.endColumn,
						presentationHint: info.artificial ? Subtle : Normal
					});
				}
				response.body = {
					stackFrames: r
				};
			});
		});
	}

	override function threadsRequest(response:ThreadsResponse) {
		connection.sendCommand(Protocol.GetThreads, {}, function(error, result) {
			if (result != null) {
				for (thread in result) {
					threads[thread.id] = true;
				}
			}
			respond(response, error, function() {
				response.body = {
					threads: result
				}
			});
		});
	}

	override function continueRequest(response:ContinueResponse, args:ContinueArguments) {
		connection.sendCommand(Protocol.Continue, args == null ? {} : {threadId: args.threadId}, function(error, _) {
			respond(response, error, function() {
				response.body = {
					allThreadsContinued: false
				}
			});
		});
	}

	override function setBreakPointsRequest(response:SetBreakpointsResponse, args:SetBreakpointsArguments) {
		if (connection == null)
			postLaunchActions.push(cb -> doSetBreakpoints(response, args));
		else
			doSetBreakpoints(response, args);
	}

	override function setFunctionBreakPointsRequest(response:SetFunctionBreakpointsResponse, args:SetFunctionBreakpointsArguments) {
		function doSetFunctionBreakpoints() {
			connection.sendCommand(Protocol.SetFunctionBreakpoints, args.breakpoints, function(error, result) {
				respond(response, error, function() {
					response.body = {breakpoints: [for (bp in result) {verified: true, id: bp.id}]};
					response.success = true;
				});
			});
		}
		if (connection == null)
			postLaunchActions.push(cb -> doSetFunctionBreakpoints())
		else
			doSetFunctionBreakpoints();
	}

	function doSetBreakpoints(response:SetBreakpointsResponse, args:SetBreakpointsArguments) {
		final params:SetBreakpointsParams = {
			file: args.source.path,
			breakpoints: [
				for (sbp in args.breakpoints) {
					final bp:{line:Int, ?column:Int, ?condition:String} = {line: sbp.line};
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
			});
		});
	}

	override function evaluateRequest(response:EvaluateResponse, args:EvaluateArguments) {
		connection.sendCommand(Protocol.Evaluate, {expr: args.expression, frameId: args.frameId}, function(error, result) {
			respond(response, error, function() {
				response.body = {
					result: result.value,
					variablesReference: result.id,
					type: result.type,
					namedVariables: result.numChildren
				}
			});
		});
	}

	override function setExceptionBreakPointsRequest(response:SetExceptionBreakpointsResponse, args:SetExceptionBreakpointsArguments) {
		connection.sendCommand(Protocol.SetExceptionOptions, args.filters, function(error, result) {
			respond(response, error, function() {});
		});
	}

	override function configurationDoneRequest(response:ConfigurationDoneResponse, args:ConfigurationDoneArguments) {
		if (!launchArgs.stopOnEntry) {
			continueRequest(cast response, null);
		} else {
			sendResponse(response);
		}
	}

	override function completionsRequest(response:CompletionsResponse, args:CompletionsArguments) {
		connection.sendCommand(Protocol.GetCompletion, args, function(error, result) {
			respond(response, error, function() {
				response.body = {
					targets: [
						for (item in result) {
							final item2:vscode.debugProtocol.DebugProtocol.CompletionItem = {label: item.label, type: item.type};
							if (item.start != null)
								item2.start = item.start;
							item2;
						}
					]
				}
			});
		});
	}

	function respond<T>(response:Response<T>, error:Null<Message.Error>, f:() -> Void) {
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
		vscode.debugAdapter.DebugSession.run(Main);
	}
}
