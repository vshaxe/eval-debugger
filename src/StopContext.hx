import protocol.debug.Types;

enum VariablesReference {
	Scope(frameId:Int, scopeNumber:Int);
	Var(frameId:Int, expr:String);
}

class StopContext {
	var connection:Connection;
	var references = new Map<Int,VariablesReference>();
	var nextId = 1;
	var currentFrameId = 0; // current is always the top one at the start

	public function new(connection) {
		this.connection = connection;
	}

	inline function getNextId() return nextId++;

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
		connection.sendCommand("scopes", function(msg:{result:Array<{id:Int, name:String}>}) {
			var scopes:Array<Scope> = [];
			for (scopeInfo in msg.result) {
				var reference = getNextId();
				references[reference] = Scope(currentFrameId, scopeInfo.id);
				scopes.push(cast new adapter.DebugSession.Scope(scopeInfo.name, reference));
			}
			callback(scopes);
		});
	}

	public function getVariables(reference:Int, callback:Array<Variable>->Void) {
		var ref = references[reference];
		if (ref == null)
			return callback([]); // is this real?

		switch (ref) {
			case Scope(frameId, scopeId):
				maybeSwitchFrame(frameId, getScopeVars.bind(frameId, scopeId, callback));
			case Var(frameId, expr):
				maybeSwitchFrame(frameId, getChildVars.bind(frameId, expr, callback));
		}
	}

	function getScopeVars(frameId:Int, scopeId:Int, callback:Array<Variable>->Void) {
		connection.sendCommand("vars_scope", "" + scopeId, function(msg:{result:Array<VarInfo>}) {
			callback([for (v in msg.result) varInfoToVariable(frameId, v, "")]);
		});
	}

	function varInfoToVariable(frameId:Int, varInfo:VarInfo, exprPrefix:String):Variable {
		var v:Variable = {name: varInfo.name, value: varInfo.value, type: varInfo.type, variablesReference: 0};
		if (varInfo.structured) {
			var reference = getNextId();
			references[reference] = Var(frameId, exprPrefix + varInfo.name);
			v.variablesReference = reference;
		}
		return v;
	}

	function getChildVars(frameId:Int, expr:String, callback:Array<Variable>->Void) {
		connection.sendCommand("vars_inner", expr, function(msg:{result:Array<VarInfo>}) {
			callback([for (v in msg.result) varInfoToVariable(frameId, v, expr + ".")]);
		});
	}
}

typedef VarInfo = {
	var name:String;
	var type:String;
	var value:String;
	var structured:Bool;
}
