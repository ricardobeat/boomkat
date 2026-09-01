// Which value formatter console output uses.
//
// This is the only file that knows the NO_INSPECT feature exists. Both
// implementations behind it — inspect.c3 and inspect_tiny.c3 — are written
// without any reference to a build flag, so neither has to be read with a
// configuration in mind.
//
// NO_INSPECT is a per-feature flag, not a build preset. Presets live in
// project.json: the boomkat_slim target simply lists every NO_* flag, so
// "slim" is a name for a set of features rather than something the code
// tests for.
//
// The four functions here are what global.c3 calls. Each has two definitions
// selected by @feat, and only the selected one is compiled; the other
// implementation is then unreferenced and the linker drops it. That is what
// makes a NO_INSPECT build actually smaller rather than merely quieter, and it
// works because these are reached by direct call. A builtin registered through
// the Builtin enum cannot be dropped this way, since the enum's static
// initializer takes the address of every handler.
module boomkat::builtins;
import boomkat::types;
import boomkat::hobject;
import boomkat::heap;

fn bool inspect_root(Heap* heap, void* vm, TVal* val, StrBuf* out) @feat(NO_INSPECT) {
    return tiny_root(heap, vm, val, out);
}

fn bool inspect_nested(Heap* heap, void* vm, TVal* val, StrBuf* out) @feat(NO_INSPECT) {
    return tiny_nested(heap, vm, val, out);
}

fn bool inspect_at_depth(Heap* heap, void* vm, TVal* val, StrBuf* out, int start_depth) @feat(NO_INSPECT) {
    return tiny_at_depth(heap, vm, val, out, start_depth);
}

fn bool inspect_has_custom_tostring(Heap* heap, HObject* obj) @feat(NO_INSPECT) {
    return tiny_has_custom_tostring(heap, obj);
}
