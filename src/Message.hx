typedef Message = {
	var ?id:Int;
	var ?method:String;
	var ?params:Dynamic;
	var ?result:Dynamic;
	var ?error:Error;
}

typedef Error = {
	var code:Int;
	var message:String;
}
