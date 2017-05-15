abstract RequestMethod<TParams,TResult>(String) to String {
	public inline function new(method) this = method;
}

abstract NotificationMethod<TParams>(String) to String {
	public inline function new(method) this = method;
}

@:publicFields
class Protocol {
	static inline var Continue = new RequestMethod<{},Void>("continue");
	static inline var StepIn = new RequestMethod<{},Void>("stepIn");
	static inline var Next = new RequestMethod<{},Void>("next");
	static inline var StepOut = new RequestMethod<{},Void>("stepOut");
	static inline var StackTrace = new RequestMethod<{},Array<StackFrameInfo>>("stackTrace");
	static inline var SetBreakpoint = new RequestMethod<SetBreakpointParams,{id:Int}>("setBreakpoint");
	static inline var RemoveBreakpoint = new RequestMethod<{id:Int},Void>("removeBreakpoint");
	static inline var SwitchFrame = new RequestMethod<{id:Int},Void>("switchFrame");
	static inline var GetScopes = new RequestMethod<{},Array<ScopeInfo>>("getScopes");
	static inline var GetScopeVariables = new RequestMethod<{},Array<VarInfo>>("getScopeVariables");
	static inline var GetStructure = new RequestMethod<{},Array<VarInfo>>("getStructure");
	static inline var SetVariable = new RequestMethod<{expr:String,value:String},VarInfo>("setVariable");

	static inline var BreakpointStop = new NotificationMethod<Void>("breakpointStop");
	static inline var ExceptionStop = new NotificationMethod<{text:String}>("exceptionStop");

}

typedef SetBreakpointParams = {
	var file:String;
	var line:Int;
	@:optional var column:Int;
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
	@:optional var pos:{source:String, line:Int, column:Int, endLine:Int, endColumn:Int};
}

/** Info about a scope variable or its subvariable (a field, array element or something) as returned by Haxe eval debugger **/
typedef VarInfo = {
	/** Variable/field name, for array elements or enum ctor arguments looks like `[0]` **/
	var name:String;
	/** Value type **/
	var type:String;
	/** Current value to display (structured child values are rendered with `...`) **/
	var value:String;
	/** True if this variable is structured, meaning that we can request "subvariables" (fields/elements) **/
	var structured:Bool;
	/** Access expression used to reference this variable.
	    For scope-level vars it's the same as name, for child vars it's an expression like `a.b[0].c[1]`.
	**/
	var access:AccessExpr;
}

typedef AccessExpr = String;
