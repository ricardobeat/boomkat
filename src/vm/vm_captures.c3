module boomkat::vm;

import boomkat::hobject;
import boomkat::env;
import boomkat::types;
import boomkat::heap;

// Capture owners remain reachable through the closure's environment chains.
// Fetch the current value array because adding bindings can resize storage.
fn TVal* capture_value_slot(Activation* act, uint index, Heap* h, bool write = false) @inline {
    if (!act.tv_func.is_object()) return null;
    HObject* fn_obj = (HObject*)act.tv_func.get_heapptr();
    HObjectFunction* fields = &(*fn_obj.extra_ptr()).func;
    if (fields.capture_refs == null || fields.comp_func == null
        || index >= fields.comp_func.capture_count) return null;
    CaptureRef ref = fields.capture_refs[index];
    if (ref.owner == null) return null;
    if (write && !ref.owner.get_prop_flags(ref.prop_idx, h).writable) return null;
    TVal* value = &ref.owner.prop_values()[ref.prop_idx];
    if (env::is_tdz_sentinel(value)) return null;
    return value;
}
