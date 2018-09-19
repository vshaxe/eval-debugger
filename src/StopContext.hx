import protocol.debug.Types;
import Protocol;

typedef ReferenceId = Int;

enum VariablesReference {
	Scope(frameId:Int, scopeNumber:Int);
	Var(frameId:Int, expr:String);
}

class StopContext {
	var connection:Connection;
	var references = new Map<ReferenceId, VariablesReference>();
	var fields = new Map<ReferenceId, Map<String, AccessExpr>>();
	var variableLut = new Map<String, Variable>();
	var nextId = 1;
	var currentFrameId = 0; // current is always the top one at the start

	public function new(connection) {
		this.connection = connection;
	}

	inline function getNextId():ReferenceId
		return nextId++;

	public function getScopes(frameId:Int, callback:Array<Scope>->Void) {
		maybeSwitchFrame(frameId, doGetScopes.bind(callback));
	}

	function maybeSwitchFrame(frameId:Int, callback:Void->Void) {
		if (currentFrameId != frameId) {
			connection.sendCommand(Protocol.SwitchFrame, {id: frameId}, function(_, _) {
				currentFrameId = frameId;
				callback();
			});
		} else {
			callback();
		}
	}

	function doGetScopes(callback:Array<Scope>->Void) {
		connection.sendCommand(Protocol.GetScopes, {}, function(error, result) {
			var scopes:Array<Scope> = [];
			for (scopeInfo in result) {
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
		if (ref == null)
			return callback(null);
		var fields = fields[reference];
		if (fields == null)
			return callback(null);
		var access = fields[name];
		if (access == null)
			return callback(null);
		switch (ref) {
			case Scope(frameId, _):
				maybeSwitchFrame(frameId, setVar.bind(access, value, callback));
			case Var(frameId, _):
				maybeSwitchFrame(frameId, setVar.bind(access, value, callback));
		}
	}

	function setVar(access:String, value:String, callback:Null<VarInfo>->Void) {
		connection.sendCommand(Protocol.SetVariable, {expr: access, value: value}, function(error, result) {
			callback(result);
		});
	}

	function getScopeVars(frameId:Int, scopeId:Int, reference:ReferenceId, callback:Array<Variable>->Void) {
		connection.sendCommand(Protocol.GetScopeVariables, {id: scopeId}, function(error, result) {
			var r = [];
			var subvars = new Map();
			fields[reference] = subvars;
			for (v in result) {
				r.push(varInfoToVariable(frameId, v));
				subvars[v.name] = v.access;
			}
			callback(r);
		});
	}

	function getChildVars(frameId:Int, expr:String, reference:ReferenceId, callback:Array<Variable>->Void) {
		connection.sendCommand(Protocol.GetStructure, {expr: expr}, function(error, result) {
			var r = [];
			var subvars = new Map();
			fields[reference] = subvars;
			for (v in result) {
				r.push(varInfoToVariable(frameId, v));
				subvars[v.name] = v.access;
			}
			callback(r);
		});
	}

	function varInfoToVariable(frameId:Int, varInfo:VarInfo):Variable {
		var v:Variable = {
			name: varInfo.name,
			value: varInfo.value,
			type: varInfo.type,
			variablesReference: 0
		};
		if (varInfo.structured) {
			var reference = getNextId();
			references[reference] = Var(frameId, varInfo.access);
			v.variablesReference = reference;
		}
		variableLut[varInfo.access] = v;
		return v;
	}

	public function browseVariables(scopes:Array<Scope>) {
		// get all variables so hovering works
		var seen = new Map();
		for (scope in scopes) {
			function explore(vars:Array<Variable>) {
				for (v in vars) {
					if (!seen.exists(v.variablesReference)) {
						seen[v.variablesReference] = true;
						getVariables(v.variablesReference, explore);
					}
				}
			}
			getVariables(scope.variablesReference, explore);
		}
	}

	public function findVar(name:String) {
		return variableLut[name];
	}
}
