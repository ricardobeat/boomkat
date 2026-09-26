// A direct eval can read any module binding by name, so no `var` here may
// live only in a register.
var z = 1;
z = 2;
export var seen = eval('z');
