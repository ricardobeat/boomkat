// ES2015 §14.5.14 + §9.2.11 SetFunctionName: a class method with a computed
// key takes its .name from the key's property-key string ("1" for [1]),
// prefixed with "get "/"set " for accessors and "[desc]" for a symbol.
//
// Regression: the compiler leaves the name empty for a computed key and the
// CLASS_INIT* handlers patch it at class-evaluation time, but they passed the
// raw key operand to the name step while converting a separate local copy for
// the property itself. A string or symbol key worked; a number, bigint or
// object key left the name "" (or a bare "get "/"set "). Object literals were
// unaffected — they take the INITPROPN path.
//
// The conversion must still happen exactly once: an object key's toString is
// observable, and ToPropertyKey runs before the name step.

function check(name, cond) {
    print((cond ? "ok   " : "FAIL ") + name);
}

var sym = Symbol("sym");
var sym2 = Symbol("sym2");
var anon = Symbol();

class C {
    [1]() {}
    *[2]() {}
    async [3]() {}
    async *[4]() {}
    ["str"]() {}
    [sym]() {}
    [anon]() {}
    [5n]() {}
    [/a/]() {}
    get [10]() {}
    set [11](v) {}
    get [sym2]() {}
    static [20]() {}
    static get [21]() {}
    static set [22](v) {}
}

var c = new C();
check("number key", c[1].name === "1");
check("generator, number key", c[2].name === "2");
check("async, number key", c[3].name === "3");
check("async generator, number key", c[4].name === "4");
check("string key", c["str"].name === "str");
check("bigint key", c[5].name === "5");
check("object (regexp) key", c["/a/"].name === "/a/");
check("static number key", C[20].name === "20");

function getter(obj, key) { return Object.getOwnPropertyDescriptor(obj, key).get; }
function setter(obj, key) { return Object.getOwnPropertyDescriptor(obj, key).set; }

check("getter, number key", getter(C.prototype, "10").name === "get 10");
check("setter, number key", setter(C.prototype, "11").name === "set 11");
check("static getter, number key", getter(C, "21").name === "get 21");
check("static setter, number key", setter(C, "22").name === "set 22");

// A described symbol is "[desc]"; an anonymous one leaves just the prefix.
check("symbol key uses [description]", c[sym].name === "[sym]");
check("anonymous symbol key has empty name", c[anon].name === "");
check("getter with symbol key", getter(C.prototype, sym2).name === "get [sym2]");

// A named function or class expression keeps its own name.
class Keeps {
    [1] = function F() {};
    [2] = class K {};
    [3] = () => {};
}
var k = new Keeps();
check("named function expression keeps its name", k[1].name === "F");
check("named class expression keeps its name", k[2].name === "K");
check("anonymous arrow field takes the key", k[3].name === "3");

// ToPropertyKey runs exactly once for an object key: toString is observable.
var calls = 0;
var keyObj = { toString: function () { calls++; return "K"; } };
class Once { [keyObj]() {} }
check("object key converted exactly once", calls === 1);
check("object key names the method", Once.prototype.K.name === "K");

var accCalls = 0;
var accKey = { toString: function () { accCalls++; return "A"; } };
class OnceAcc { get [accKey]() { return 1; } }
check("object key converted once for an accessor", accCalls === 1);
check("object key names the accessor", getter(OnceAcc.prototype, "A").name === "get A");

// Object literals keep working (the INITPROPN path).
var o = { [1]: function () {}, [2]() {}, get [3]() {}, [sym]: function () {} };
check("object literal, number key", o[1].name === "1");
check("object literal method, number key", o[2].name === "2");
check("object literal getter, number key", getter(o, "3").name === "get 3");
check("object literal, symbol key", o[sym].name === "[sym]");

print("=== DONE ===");
