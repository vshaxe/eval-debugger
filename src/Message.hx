typedef Message<T> = {
    @:optional var event:String;
    @:optional var result:T;
    @:optional var error:String;
}
