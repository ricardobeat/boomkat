// P6: `#x in obj` outside of any class body is a SyntaxError — #x must
// resolve to a declared private name in an enclosing class.
var r = (#x in {});
