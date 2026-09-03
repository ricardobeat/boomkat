// Array.prototype.shift (ES2022 §23.1.3.31 step 5.b-d) must call
// HasProperty(O, from) BEFORE Get(O, from) for each source index it shifts
// -- these are observably separate operations on a Proxy (a "has" trap call
// followed by a "get" trap call), not a single combined presence-check.
// The engine only ever called [[Get]] (via arr_get_elem_vm) and inferred
// presence from whether that returned a value, so no "has" trap call ever
// happened.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

var log = [];
var array = [2, 3];
var proxy = new Proxy(array, new Proxy({}, {
    get(t, trap, r) {
        return (t, pk, ...more) => {
            log.push(trap + ":" + String(pk));
            return Reflect[trap](t, pk, ...more);
        };
    },
}));

var result = Array.prototype.shift.call(proxy);
check("shift return value", result, 2);

var hasIdx = log.indexOf("has:1");
var getIdx = log.indexOf("get:1");
check("has:1 trap was called", hasIdx >= 0, true);
check("get:1 trap was called", getIdx >= 0, true);
check("has:1 precedes get:1", hasIdx < getIdx, true);

// A hole (absent source index) must still delete the target slot, without
// ever calling "get" for the absent index.
{
    var log2 = [];
    var sparse = [1];
    sparse[2] = 3; // index 1 is a hole
    var proxy2 = new Proxy(sparse, new Proxy({}, {
        get(t, trap, r) {
            return (t, pk, ...more) => {
                log2.push(trap + ":" + String(pk));
                return Reflect[trap](t, pk, ...more);
            };
        },
    }));
    Array.prototype.shift.call(proxy2);
    check("hole: has:1 was called", log2.indexOf("has:1") >= 0, true);
    check("hole: get:1 was NOT called", log2.indexOf("get:1"), -1);
    check("hole: deleteProperty:0 was called", log2.indexOf("deleteProperty:0") >= 0, true);
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
