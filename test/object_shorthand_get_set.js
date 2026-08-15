// `get`/`set` open an accessor only when a PropertyName actually follows.
// The object-literal parser excluded just `:` and `(` after the contextual
// keyword, so every other shorthand form (`{ get, set }`, `{ get }`,
// `{ get = d }`) was misparsed as an accessor with a missing name and failed
// with a positionless compile error. typescript 5.4.5 hit this on
// `return { get, set };`.

function check(label, got, want) {
    var g = JSON.stringify(got), w = JSON.stringify(want);
    if (g !== w) { print("FAIL " + label + ": got " + g + " want " + w); }
}

// --- shorthand properties literally named get/set ---------------------------

function shorthandPair() {
    var get = 1, set = 2;
    return { get, set };
}
check("{ get, set } shorthand", shorthandPair(), { get: 1, set: 2 });

function shorthandSingleGet() {
    var get = 3;
    return { get };
}
check("{ get } shorthand", shorthandSingleGet(), { get: 3 });

function shorthandSingleSet() {
    var set = 4;
    return { set };
}
check("{ set } shorthand", shorthandSingleSet(), { set: 4 });

function shorthandWithDefaults(o) {
    var { get = 9, set = 8 } = o;
    return [get, set];
}
check("destructuring defaults named get/set", shorthandWithDefaults({}), [9, 8]);
check("destructuring values named get/set", shorthandWithDefaults({ get: 1, set: 2 }), [1, 2]);

// --- data properties keyed get/set ------------------------------------------

check("{ get: v } data property", { get: 5, set: 6 }, { get: 5, set: 6 });

function methodsNamedGetSet() {
    var o = { get() { return "g"; }, set(v) { return "s" + v; } };
    return [o.get(), o.set(1)];
}
check("methods named get/set", methodsNamedGetSet(), ["g", "s1"]);

// --- real accessors must still work -----------------------------------------

function realAccessors() {
    var backing = 0;
    var o = {
        get value() { return backing; },
        set value(v) { backing = v * 2; },
    };
    o.value = 21;
    return o.value;
}
check("real get/set accessors", realAccessors(), 42);

function accessorNamedByKeyword() {
    var o = { get break() { return "b"; }, set break(v) {} };
    return o.break;
}
check("accessor whose name is a keyword", accessorNamedByKeyword(), "b");

function computedAccessor() {
    var k = "dyn";
    var o = { get [k]() { return "c"; } };
    return o.dyn;
}
check("computed accessor key", computedAccessor(), "c");

function numericAccessor() {
    var o = { get 7() { return "n"; } };
    return o[7];
}
check("numeric accessor key", numericAccessor(), "n");

// Accessor function names carry the "get "/"set " prefix (ES2015 §14.3).
var named = { get foo() { return 1; } };
check("accessor name prefix",
      Object.getOwnPropertyDescriptor(named, "foo").get.name, "get foo");

print("object_shorthand_get_set: done");
