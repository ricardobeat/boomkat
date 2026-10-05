function equal(actual, expected) {
    if (actual !== expected) throw new Error(String(actual) + " !== " + String(expected));
}
function methods() {
    var value = 1;
    var object = {
        m() { return this; },
        get x() { return value; },
        set x(v) { value = v; },
        get 7() { return 7; },
        ["computed"]() { return this.x; }
    };
    equal(object.m(), object);
    equal(object.m.name, "m");
    equal(object.computed.name, "computed");
    equal(Object.getOwnPropertyDescriptor(object, "x").get.name, "get x");
    equal(Object.getOwnPropertyDescriptor(object, "7").get.name, "get 7");
    equal(Object.prototype.hasOwnProperty.call(object.m, "prototype"), false);
    var threw = false;
    try { new object.m(); } catch (e) { threw = e instanceof TypeError; }
    equal(threw, true);
    object.x = 8;
    equal(object.computed(), 8);
}
function operators() {
    var gets = 0, sets = 0, value = 0;
    var object = { get x() { gets++; return value; }, set x(v) { sets++; value = v; } };
    equal(object.x &&= 3, 0);
    equal(sets, 0);
    equal(object.x ||= 4, 4);
    equal(object.x ??= 5, 4);
    equal(gets, 3);
    equal(sets, 1);
    var fn;
    fn ??= () => 42;
    equal(fn.name, "fn");
    equal(fn(), 42);
    const constant = 1;
    equal(constant ||= 9, 1);
    var threw = false;
    try { constant &&= 9; } catch (e) { threw = e instanceof TypeError; }
    equal(threw, true);
    equal(constant, 1);
    var original = { x: 0 }, base = original;
    base.x ||= (base = {}, 6);
    equal(original.x, 6);
    equal(typeof object.x, "number");
    equal(object.x, 4);
    equal(delete object.x, true);
    equal(gets, 5);
    equal(delete absentAstName, true);
    equal(delete value, false);
    equal(delete undefined, false);
}
methods();
operators();

function logicalAssignmentValues() {
    var a = 1;
    equal((a &&= 2) + (a = 4), 6);
    a = 0;
    equal((a ||= 2) + (a = 4), 6);
    a = null;
    equal((a ??= 2) + (a = 4), 6);
    a = 0;
    equal((a &&= 2) + (a = 4), 4);
    a = 1;
    equal((a ||= 2) + (a = 4), 5);
    a = 1;
    equal((a ??= 2) + (a = 4), 5);
    a = 1;
    equal(((a &&= 2) || 3) + (a = 4), 6);
}
logicalAssignmentValues();
