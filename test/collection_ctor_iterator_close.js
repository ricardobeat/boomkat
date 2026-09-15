// ES2017 §23.1.1.1 (Map), §23.2.1.1 (Set), §23.3.1.1 (WeakMap), §23.4.1.1
// (WeakSet) and §23.1.2.1 / §7.3.34 (groupBy) drive AddEntriesFromIterable.
//
// IteratorClose (§7.4.6) runs only for an abrupt completion of the *loop body*.
// A throw from next(), or from the done / value getters on the iterator result
// object, is the iterator's own abrupt completion inside IteratorStep /
// IteratorValue, and the iterator is NOT closed.
//
// Regression: the collection constructors called IteratorClose when the done
// or value getter threw, and Object.groupBy / Map.groupBy did the same for the
// value getter, so iterator.return() ran when it must not. Array.from, spread,
// destructuring and for-of were already correct.

function check(name, cond) {
    print((cond ? "ok   " : "FAIL ") + name);
}

function makeIterable(opts) {
    var iterable = { closed: false };
    iterable[Symbol.iterator] = function () {
        var first = true;
        var iterator = {
            next: function () {
                if (first) {
                    first = false;
                    if (opts.nextThrow) throw opts.nextThrow;
                    return opts.nextVal;
                }
                return { value: undefined, done: true };
            },
            "return": function () { iterable.closed = true; return {}; }
        };
        return iterator;
    };
    return iterable;
}

var ctors = [["Map", Map], ["Set", Set], ["WeakMap", WeakMap], ["WeakSet", WeakSet]];

// --- Not closed: the iterator's own step completed abruptly. ---

var notClosed = [
    ["next() throws", { nextThrow: "next throws" }],
    ["done getter throws", { nextVal: { value: {}, get done() { throw "done throws"; } } }],
    ["value getter throws", { nextVal: { get value() { throw "value throws"; }, done: false } }]
];

for (var i = 0; i < ctors.length; i++) {
    for (var j = 0; j < notClosed.length; j++) {
        var it = makeIterable(notClosed[j][1]);
        var threw = false;
        try { new ctors[i][1](it); } catch (e) { threw = true; }
        check(ctors[i][0] + ": " + notClosed[j][0] + " does not close", it.closed === false);
        check(ctors[i][0] + ": " + notClosed[j][0] + " still propagates", threw === true);
    }
}

// groupBy takes the same path.
var groupBys = [["Object.groupBy", Object.groupBy], ["Map.groupBy", Map.groupBy]];
for (var g = 0; g < groupBys.length; g++) {
    for (var h = 0; h < notClosed.length; h++) {
        var git = makeIterable(notClosed[h][1]);
        var gthrew = false;
        try { groupBys[g][1](git, function () { return "k"; }); } catch (e) { gthrew = true; }
        check(groupBys[g][0] + ": " + notClosed[h][0] + " does not close", git.closed === false);
        check(groupBys[g][0] + ": " + notClosed[h][0] + " still propagates", gthrew === true);
    }
}

// --- Closed: the loop body completed abruptly. ---

// A non-object entry for Map/WeakMap is a TypeError raised by the body.
var e1 = makeIterable({ nextVal: { value: "non object", done: false } });
var t1 = null;
try { new Map(e1); } catch (e) { t1 = e; }
check("Map: non-object entry closes", e1.closed === true);
check("Map: non-object entry throws TypeError", t1 instanceof TypeError);

// Reading entry[0] / entry[1] happens in the body, so a throwing getter closes.
var e2 = makeIterable({ nextVal: { value: { get 0() { throw "k getter"; } }, done: false } });
var t2 = null;
try { new Map(e2); } catch (e) { t2 = e; }
check("Map: entry[0] getter throws closes", e2.closed === true);
check("Map: entry[0] getter error propagates", t2 === "k getter");

var e3 = makeIterable({ nextVal: { value: { 0: {}, get 1() { throw "v getter"; } }, done: false } });
var t3 = null;
try { new Map(e3); } catch (e) { t3 = e; }
check("Map: entry[1] getter throws closes", e3.closed === true);
check("Map: entry[1] getter error propagates", t3 === "v getter");

// A throwing set/add on a subclass is also the body.
class ThrowingMap extends Map { set(k, v) { throw "setter throws"; } }
var e4 = makeIterable({ nextVal: { value: [{}, {}], done: false } });
var t4 = null;
try { new ThrowingMap(e4); } catch (e) { t4 = e; }
check("Map subclass: throwing set closes", e4.closed === true);
check("Map subclass: throwing set propagates", t4 === "setter throws");

class ThrowingSet extends Set { add(v) { throw "adder throws"; } }
var e5 = makeIterable({ nextVal: { value: {}, done: false } });
var t5 = null;
try { new ThrowingSet(e5); } catch (e) { t5 = e; }
check("Set subclass: throwing add closes", e5.closed === true);
check("Set subclass: throwing add propagates", t5 === "adder throws");

// A successful run never closes: the iterator ran to done.
var e6 = makeIterable({ nextVal: { value: [{}, {}], done: false } });
new Map(e6);
check("Map: successful iteration does not close", e6.closed === false);

// --- IteratorClose swallows its own errors (§7.4.6 step 5/6). ---
// The body's exception wins over anything return() does.
function closingIterable(returnImpl) {
    var iterable = { closed: false };
    iterable[Symbol.iterator] = function () {
        var first = true;
        var it = { next: function () {
            if (first) { first = false; return { value: [{}, {}], done: false }; }
            return { value: undefined, done: true };
        } };
        returnImpl(it, iterable);
        return it;
    };
    return iterable;
}

var variants = [
    ["return getter throws", function (it, iterable) {
        Object.defineProperty(it, "return", { get: function () { iterable.closed = true; throw "return getter"; } });
    }],
    ["return is not an object result", function (it, iterable) {
        it["return"] = function () { iterable.closed = true; return "non object"; };
    }],
    ["return itself throws", function (it, iterable) {
        it["return"] = function () { iterable.closed = true; throw "return throws"; };
    }]
];

for (var v = 0; v < variants.length; v++) {
    var ci = closingIterable(variants[v][1]);
    var ct = null;
    try { new ThrowingMap(ci); } catch (e) { ct = e; }
    check("close error ignored, body error wins (" + variants[v][0] + ")", ct === "setter throws");
    check("close was attempted (" + variants[v][0] + ")", ci.closed === true);
}

print("=== DONE ===");
