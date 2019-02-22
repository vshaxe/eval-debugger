abstract RequestMethod<TParams, TResult>(String) to String {
	public inline function new(method)
		this = method;
}

abstract NotificationMethod<TParams>(String) to String {
	public inline function new(method)
		this = method;
}

typedef ScopeArgs = {
	var frameId:Int;
}

typedef ScopeVarsArgs = {
	var id:Int;
}

typedef GetStructureArgs = {
	var expr:String;
}

typedef SetVariableArgs = {
	var id:Int;
	var name:String;
	var value:String;
}

typedef EvaluateArgs = {
	var frameId:Int;
	var expr:String;
}

@:publicFields
class Protocol {
	static inline var Continue = new RequestMethod<{}, Void>("continue");
	static inline var StepIn = new RequestMethod<{}, Void>("stepIn");
	static inline var Next = new RequestMethod<{}, Void>("next");
	static inline var StepOut = new RequestMethod<{}, Void>("stepOut");
	static inline var StackTrace = new RequestMethod<{}, Array<StackFrameInfo>>("stackTrace");
	static inline var SetBreakpoints = new RequestMethod<SetBreakpointsParams, Array<{id:Int}>>("setBreakpoints");
	static inline var SetFunctionBreakpoints = new RequestMethod<SetFunctionBreakpointsParams, Array<{id:Int}>>("setFunctionBreakpoints");
	static inline var SetBreakpoint = new RequestMethod<SetBreakpointParams, {id:Int}>("setBreakpoint");
	static inline var RemoveBreakpoint = new RequestMethod<{id:Int}, Void>("removeBreakpoint");
	static inline var GetScopes = new RequestMethod<ScopeArgs, Array<ScopeInfo>>("getScopes");
	static inline var GetScopeVariables = new RequestMethod<ScopeVarsArgs, Array<VarInfo>>("getScopeVariables");
	static inline var GetStructure = new RequestMethod<GetStructureArgs, Array<VarInfo>>("getStructure");
	static inline var SetVariable = new RequestMethod<SetVariableArgs, VarInfo>("setVariable");
	static inline var BreakpointStop = new NotificationMethod<Void>("breakpointStop");
	static inline var ExceptionStop = new NotificationMethod<{text:String}>("exceptionStop");
	static inline var Evaluate = new RequestMethod<EvaluateArgs, VarInfo>("evaluate");
	static inline var SetExceptionOptions = new RequestMethod<Array<String>, Void>("setExceptionOptions");
	static inline var GetCompletion = new RequestMethod<GetCompletionParams, Array<CompletionItem>>("getCompletion");
}

typedef GetCompletionParams = {
	var text:String;
	var column:Int;
}

typedef CompletionItem = {
	var label:String;
	var type:String;
	var ?start:Int;
}

typedef SetBreakpointsParams = {
	var file:String;
	var breakpoints:Array<{line:Int, ?column:Int}>;
}

typedef SetFunctionBreakpointsParams = Array<{
	var name:String;
}>;

typedef SetBreakpointParams = {
	var file:String;
	var line:Int;
	var ?column:Int;
}

typedef StackFrameInfo = {
	var id:Int;
	var name:String;
	var source:String;
	var line:Int;
	var column:Int;
	var endLine:Int;
	var endColumn:Int;
	var artificial:Bool;
}

/** Info about a scope **/
typedef ScopeInfo = {
	/** Scope identifier to use for the `vars` request. **/
	var id:Int;

	/** Name of the scope (e.g. Locals, Captures, etc) **/
	var name:String;

	/** Position information about scope boundaries, if present **/
	var ?pos:{
		source:String,
		line:Int,
		column:Int,
		endLine:Int,
		endColumn:Int
	};
}

/** Info about a scope variable or its subvariable (a field, array element or something) as returned by Haxe eval debugger **/
typedef VarInfo = {
	/** A unique identifier for this variable. **/
	var id:Int;

	/** Variable/field name, for array elements or enum ctor arguments looks like `[0]` **/
	var name:String;

	/** Value type **/
	var type:String;

	/** Current value to display (structured child values are rendered with `...`) **/
	var value:String;
}

typedef AccessExpr = String;
