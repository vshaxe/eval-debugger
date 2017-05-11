import protocol.debug.Types;

typedef ReferenceId = Int;
typedef AccessExpr = String;

enum VariablesReference {
	Scope(frameId:Int, scopeNumber:Int);
	Var(frameId:Int, expr:String);
}

class StopContext {
	var connection:Connection;
	var references = new Map<ReferenceId,VariablesReference>();
	var fields = new Map<ReferenceId,Map<String,AccessExpr>>();
	var nextId = 1;
	var currentFrameId = 0; // current is always the top one at the start

	public function new(connection) {
		this.connection = connection;
	}

	inline function getNextId():ReferenceId return nextId++;

	public function getScopes(frameId:Int, callback:Array<Scope>->Void) {
		maybeSwitchFrame(frameId, doGetScopes.bind(callback));
	}

	function maybeSwitchFrame(frameId:Int, callback:Void->Void) {
		if (currentFrameId != frameId) {
			connection.sendCommand("frame", "" + frameId, function(_) {
				currentFrameId = frameId;
				callback();
			});
		} else {
			callback();
		}
	}

	function doGetScopes(callback:Array<Scope>->Void) {
		connection.sendCommand("scopes", function(msg:{result:Array<ScopeInfo>}) {
			var scopes:Array<Scope> = [];
			for (scopeInfo in msg.result) {
				var reference = getNextId();
				references[reference] = Scope(currentFrameId, scopeInfo.id);
				var scope:Scope = cast new adapter.DebugSession.Scope(scopeInfo.name, reference);
				if (scopeInfo.pos != null) {
					var p = scopeInfo.pos;
					scope.source = {path: p.source};
					scope.line = p.line;
					scope.column = p.column;
					scope.endLine = p.endLine;
					scope.endColumn = p.endColumn;
				}
				scopes.push(scope);
			}
			callback(scopes);
		});
	}

	public function getVariables(reference:ReferenceId, callback:Array<Variable>->Void) {
		var ref = references[reference];
		if (ref == null)
			return callback([]); // is this real?

		switch (ref) {
			case Scope(frameId, scopeId):
				maybeSwitchFrame(frameId, getScopeVars.bind(frameId, scopeId, reference, callback));
			case Var(frameId, expr):
				maybeSwitchFrame(frameId, getChildVars.bind(frameId, expr, reference, callback));
		}
	}

	public function setVariable(reference:ReferenceId, name:String, value:String, callback:Null<VarInfo>->Void) {
		var ref = references[reference];
		if (ref == null) return callback(null);
		var fields = fields[reference];
		if (fields == null) return callback(null);
		var access = fields[name];
		if (access == null) return callback(null);
		switch (ref) {
			case Scope(frameId, _):
				callback(null);
				maybeSwitchFrame(frameId, setVar.bind(access, value, callback));
			case Var(frameId, _):
				maybeSwitchFrame(frameId, setVar.bind(access, value, callback));
		}
	}

	function setVar(access:String, value:String, callback:Null<VarInfo>->Void) {
		connection.sendCommand("s", '$access = $value', function(msg:{?result:VarInfo, ?error:String}) {
			callback(msg.result);
		});
	}

	function getScopeVars(frameId:Int, scopeId:Int, reference:ReferenceId, callback:Array<Variable>->Void) {
		connection.sendCommand("vars", "" + scopeId, function(msg:{result:Array<VarInfo>}) {
			var result = [];
			var subvars = new Map();
			fields[reference] = subvars;
			for (v in msg.result) {
				result.push(varInfoToVariable(frameId, v));
				subvars[v.name] = v.access;
			}
			callback(result);
		});
	}

	function getChildVars(frameId:Int, expr:String, reference:ReferenceId, callback:Array<Variable>->Void) {
		connection.sendCommand("structure", expr, function(msg:{result:Array<VarInfo>}) {
			var result = [];
			var subvars = new Map();
			fields[reference] = subvars;
			for (v in msg.result) {
				result.push(varInfoToVariable(frameId, v));
				subvars[v.name] = v.access;
			}
			callback(result);
		});
	}

	function varInfoToVariable(frameId:Int, varInfo:VarInfo):Variable {
		var v:Variable = {name: varInfo.name, value: varInfo.value, type: varInfo.type, variablesReference: 0};
		if (varInfo.structured) {
			var reference = getNextId();
			references[reference] = Var(frameId, varInfo.access);
			v.variablesReference = reference;
		}
		return v;
	}
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

/** Info about a scope **/
typedef ScopeInfo = {
	/** Scope identifier to use for the `vars` request. **/
	var id:Int;
	/** Name of the scope (e.g. Locals, Captures, etc) **/
	var name:String;
	/** Position information about scope boundaries, if present **/
	@:optional var pos:{source:String, line:Int, column:Int, endLine:Int, endColumn:Int};
}
