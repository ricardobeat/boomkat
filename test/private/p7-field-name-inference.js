// P7: an anonymous function/arrow assigned as a field initializer infers
// its .name from the field's key (SetFunctionName), same as var/let/const.
class A {
    x = () => {};
    y = function () {};
}

var a = new A();
if (a.x.name !== "x") throw new Error("expected name 'x', got " + JSON.stringify(a.x.name));
if (a.y.name !== "y") throw new Error("expected name 'y', got " + JSON.stringify(a.y.name));

print("PASS");
