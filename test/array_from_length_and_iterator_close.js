// Regression coverage for several Array.from bugs fixed together:
//
// 1. Set(A, "length", ...) must reject a write when A is non-extensible and
//    "length" has no own property yet (OrdinarySet's CreateDataProperty step
//    requires extensibility).
// 2. The same Set must also reject when "length" is inherited as a
//    non-writable DATA property from A's prototype chain. The shared
//    find_accessor_proto helper reports found=false for a data property
//    (by design, for its other callers), so Array.from's length-setter must
//    re-check that case itself.
// 3. GetV(items, @@iterator) must invoke an inherited accessor getter with
//    `this` = the original (possibly primitive) items value, not the
//    throwaway wrapper object used to walk the primitive's prototype chain.
// 4. IsConstructor(C) requires callable AND constructable; an arrow function
//    is callable but never constructable, so `Array.from.call(arrowFn, ...)`
//    must produce a plain Array, never attempt Construct(arrowFn).
// 5. arr_iterator_close_after_throw must invoke an accessor "return"
//    property's getter (not just check for an own data property), and must
//    preserve the caller's already-pending exception across that nested
//    property get instead of clobbering it.
// 6. A throwing IteratorValue (the `value` getter on the step result) must
//    NOT trigger IteratorClose — only iterator.next()/done and the
//    map/CreateDataProperty steps that consume nextValue do.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// --- 1: inextensible target, "length" has no own property yet ---
{
    function Inext() { Object.preventExtensions(this); }
    Inext.from = Array.from;
    var threw = false;
    try { Inext.from([]); } catch (e) { threw = e instanceof TypeError; }
    check("Set(length) on inextensible target throws", threw, true);
}

// --- 2: inherited non-writable "length" on the constructor's .prototype ---
{
    function C() {}
    Object.defineProperty(C.prototype, "length",
        { configurable: true, writable: false, value: 4 });
    C.from = Array.from;
    var threw = false;
    try { C.from([]); } catch (e) { threw = e instanceof TypeError; }
    check("Set(length) over inherited read-only length throws", threw, true);
}

// --- 3: @@iterator getter's `this` must be the original primitive ---
{
    var seenThis;
    Object.defineProperty(Boolean.prototype, Symbol.iterator, {
        configurable: true,
        get() {
            seenThis = typeof this;
            return () => [this][Symbol.iterator]();
        },
    });
    var r = Array.from(true);
    delete Boolean.prototype[Symbol.iterator];
    check("primitive @@iterator getter sees primitive `this`", seenThis, "boolean");
    check("primitive @@iterator getter result value", r[0], true);
}

// --- 4: arrow function is callable but not constructable ---
{
    var arr = [3, 4, 5];
    var obj = Array.from.call(() => ({}), arr);
    check("Array.from.call(arrowFn) produces a plain Array", Array.isArray(obj), true);
}

// --- 5+6: iterator close semantics ---
{
    function makeIterable(opts) {
        var closed = false;
        var iterable = {};
        iterable[Symbol.iterator] = function () {
            var iterator = {
                first: true,
                next() {
                    if (this.first) {
                        this.first = false;
                        if (opts.nextThrows) throw opts.nextThrows;
                        return opts.nextVal;
                    }
                    return { value: undefined, done: true };
                },
            };
            if (opts.returnGetterThrows) {
                Object.defineProperty(iterator, "return", {
                    get: function () { closed = true; throw opts.returnGetterThrows; },
                });
            } else {
                iterator.return = function () { closed = true; return {}; };
            }
            return iterator;
        };
        return { iterable, isClosed: () => closed };
    }

    // mapfn throws -> must close, and the original throw must propagate
    // (not get overwritten by the nested "return" property get).
    {
        var m = makeIterable({ nextVal: { value: 1, done: false } });
        var caught;
        try {
            Array.from(m.iterable, () => { throw "map throws"; });
        } catch (e) { caught = e; }
        check("mapfn throw propagates through iterator close", caught, "map throws");
        check("mapfn throw closes the iterator", m.isClosed(), true);
    }

    // an accessor "return" property's getter must run (and its own throw
    // must not mask the original completion).
    {
        var m = makeIterable({
            nextVal: { value: 1, done: false },
            returnGetterThrows: "return getter throws",
        });
        var caught;
        try {
            Array.from(m.iterable, () => { throw "map throws"; });
        } catch (e) { caught = e; }
        check("accessor return-getter throw is swallowed", caught, "map throws");
        check("accessor return-getter still observed as closing", m.isClosed(), true);
    }

    // a throwing IteratorValue (the `value` getter) must NOT close.
    {
        var closed = false;
        var iterable = {
            [Symbol.iterator]() {
                return {
                    first: true,
                    next() {
                        if (this.first) {
                            this.first = false;
                            return { get value() { throw "value getter throws"; }, done: false };
                        }
                        return { value: undefined, done: true };
                    },
                    return() { closed = true; return {}; },
                };
            },
        };
        var caught;
        try { Array.from(iterable); } catch (e) { caught = e; }
        check("IteratorValue throw propagates", caught, "value getter throws");
        check("IteratorValue throw does not close the iterator", closed, false);
    }
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
