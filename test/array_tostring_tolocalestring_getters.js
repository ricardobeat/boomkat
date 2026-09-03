// Array.prototype.toString and Array.prototype.toLocaleString both used raw
// data-property lookups (get_prop_proto) for "join" / "toLocaleString"
// instead of a full [[Get]], which:
//   (a) never invokes an inherited accessor's getter at all, silently
//       swallowing any throw from it and falling through as if the
//       property were simply absent;
//   (b) for toLocaleString specifically, even if the getter WERE invoked,
//       calling it on the boxed wrapper object instead of the original
//       primitive element would give the getter the wrong `this`.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// --- Array.prototype.toString: a throwing "join" getter must propagate ---
{
    var o = { get join() { throw 42; } };
    var caught;
    try {
        Array.prototype.toString.call(o);
    } catch (e) {
        caught = e;
    }
    check("toString propagates a throwing join getter", caught, 42);
}

// --- Array.prototype.toLocaleString: a String.prototype.toLocaleString
//     getter must see the ORIGINAL primitive element as `this` ---
{
    var seenThis;
    Object.defineProperty(String.prototype, "toLocaleString", {
        configurable: true,
        get() {
            seenThis = typeof this;
            return function () { return typeof this; };
        },
    });
    var result = ["test"].toLocaleString();
    delete String.prototype.toLocaleString;
    check("toLocaleString getter sees the primitive `this`", seenThis, "string");
    check("toLocaleString call also sees the primitive `this`", result, "string");
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
