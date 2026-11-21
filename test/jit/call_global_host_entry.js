// GETGLOBAL read inside a host callback (Array.prototype.some) on the
// callback's very first call: with --opt-always the optimizing tier compiles
// the callback before the interpreter ever runs it, so the function's
// variable inline-cache array (CompiledFunction.var_ic_entries), allocated
// lazily on a frame's first dispatch, does not exist yet. The build phase
// must treat that as "no cache" the same way PUTGLOBAL already does, rather
// than bake an offset into a null base that the fast path then dereferences.
var total = 0, hay = "ab".repeat(40) + "c", needle = "abc";
var cb = function () {
    var s = 0;
    for (var p = -2; p <= hay.length + 2; p++) {
        if (hay.indexOf(needle, p) >= 0) s++;
        if (hay.lastIndexOf(needle, p) >= 0) s++;
    }
    total += s;
};
[1].some(cb);
print(total === 87 ? "call_global_host_entry ok" : "call_global_host_entry FAIL " + total);
