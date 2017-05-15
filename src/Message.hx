typedef Message = {
	@:optional var id:Int;
	@:optional var method:String;
	@:optional var params:Dynamic;
	@:optional var result:Dynamic;
	@:optional var error:Error;
}

typedef Error = {
	var code:Int;
	var message:String;
}
