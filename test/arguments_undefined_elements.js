// An `undefined` argument is an ordinary present element, and `delete
// arguments[i]` still removes one. ARGUMENTS objects therefore keep their
// elements in the named property table: the dense part marks a hole with
// `undefined` and cannot tell the two apart.
var pass = 0, fail = 0;

function ok(cond, name) {
    if (cond) { pass = pass + 1; } else { print("FAIL: " + name); fail = fail + 1; }
}

function eq(a, b, name) { ok(JSON.stringify(a) === JSON.stringify(b), name); }

(function (a, b, c) {
    ok(arguments.length === 3, "length counts an undefined argument");
    ok(2 in arguments, "`in` finds an undefined argument");
    ok(arguments.hasOwnProperty(2), "hasOwnProperty finds it");
    eq(Object.keys(arguments), ["0", "1", "2"], "Object.keys lists it");
    ok(Object.values(arguments)[2] === undefined, "Object.values yields it");
    ok([...arguments].length === 3, "spread keeps its position");
    ok(arguments.propertyIsEnumerable(2), "it is enumerable");
    var seen = 0;
    Array.prototype.forEach.call(arguments, function () { seen++; });
    ok(seen === 3, "forEach visits it");
}(0, "a", undefined));

// delete must still produce a real hole.
(function () {
    delete arguments[0];
    ok(!(0 in arguments), "delete removes the index");
    eq(Object.keys(arguments), ["1", "2"], "deleted index leaves the key list");
    ok(arguments.length === 3, "delete does not change length");
}(0, 1, 2));

// Past the 64-index [[ParameterMap]] cap.
(function () {
    ok(arguments.length === 70, "70 arguments: length");
    ok(69 in arguments, "70 arguments: last index present");
    ok(Object.keys(arguments).length === 70, "70 arguments: all keys listed");
}.apply(null, new Array(70)));

// Dense arrays: storing undefined creates a property, a hole stays a hole.
var arr = [0, 1];
arr[2] = undefined;
ok(2 in arr, "array: assigned undefined is present");
eq(Object.keys(arr), ["0", "1", "2"], "array: assigned undefined is listed");
var pushed = [0];
pushed.push(undefined);
ok(1 in pushed, "array: pushed undefined is present");
var holed = [0, 1, , ];
ok(!(2 in holed), "array: elision stays a hole");
eq(Object.keys(holed), ["0", "1"], "array: elision is not listed");

print("pass: " + pass + ", fail: " + fail);
if (fail !== 0) { throw new Error(fail + " failures"); }
