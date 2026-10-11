(function () {
    function check(condition, message) {
        if (!condition) throw new Error(message);
    }
    ["console", "Temporal", "Intl", "BigInt", "BigInt64Array", "BigUint64Array", "Proxy"].forEach(function (name) {
        check(!Object.prototype.hasOwnProperty.call(globalThis, name), name + " must be excluded");
    });
    check(!Object.prototype.hasOwnProperty.call(Date.prototype, "toTemporalInstant"), "Temporal Date hook must be excluded");
    check(typeof print === "function", "print");
    check(typeof WeakRef === "function" && typeof FinalizationRegistry === "function", "weak references");
    check(Iterator.from([1, 2]).map(function (x) { return x * 2; }).toArray()[1] === 4, "Iterator helpers");
    check(Atomics.add(new Int32Array(new SharedArrayBuffer(4)), 0, 2) === 0, "shared memory");
    check("é".normalize("NFD") === "e\u0301", "normalization");
    check(new Map([["a", 42]]).get("a") === 42, "Map");
    check(new Set([1, 1, 2]).size === 2, "Set");
    check(new Uint8Array([1, 2]).map(function (x) { return x * 2; })[1] === 4, "typed arrays");
    check(typeof DataView.prototype.getBigInt64 === "undefined", "BigInt buffer APIs");
    check((function () { return this; })() === undefined, "strict functions");
    check(Function("return this")() === undefined, "strict Function constructor");
    check((0, eval)("(function () { return this; })()") === undefined, "strict indirect eval");
    function unmapped(a) { arguments[0] = 2; return a; }
    check(unmapped(1) === 1, "unmapped arguments");
    check(/\p{Letter}+/u.test("abc"), "Unicode RegExp");
    check(JSON.parse(JSON.stringify({a: 42})).a === 42, "JSON");
    check(new Date(0).getUTCFullYear() === 1970, "Date");
    check((1234.5).toLocaleString() === (1234.5).toString(), "locale fallback");
    check(eval("6 * 7") === 42, "eval");
    function* values() { yield 42; }
    check(values().next().value === 42, "generators");
    Promise.resolve(42).then(function (value) {
        check(value === 42, "Promise");
        print("slim smoke passed");
    });
})();
