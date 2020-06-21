typedef Message = {
	final ?id:Int;
	final ?method:String;
	final ?params:Dynamic;
	final ?result:Dynamic;
	final ?error:Error;
}

typedef Error = {
	final code:Int;
	final message:String;
}
