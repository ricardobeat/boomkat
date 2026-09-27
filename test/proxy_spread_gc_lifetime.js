// CopyDataProperties keeps its materialized key list across descriptor traps.
var symbol = Symbol("key");
var expected = [symbol, "foo", "0"];
var seen = [];
var proxy = new Proxy({}, {
    ownKeys: function () { return expected; },
    getOwnPropertyDescriptor: function (target, key) {
        seen.push(key);
        for (var i = 0; i < 100; i++) ({ value: i });
        return undefined;
    }
});

function check(label) {
    if (seen.length !== expected.length) throw new Error(label + ": key count");
    for (var i = 0; i < expected.length; i++) {
        if (seen[i] !== expected[i]) throw new Error(label + ": key order");
    }
    seen = [];
}

var spread = { ...proxy };
check("spread");
var { ...rest } = proxy;
check("rest");
if (Object.keys(proxy).length !== 0) throw new Error("keys: unexpected descriptor");
// Object.keys filters symbols before requesting descriptors.
if (seen.length !== 2 || seen[0] !== "foo" || seen[1] !== "0") {
    throw new Error("keys: descriptor order");
}
print("PASS: scoped Proxy key lists survive descriptor callbacks");
