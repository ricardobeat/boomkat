/// Boolean constructor and Boolean.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::env;
import duktape::hstring;

import duktape::heap;
import duktape::hobject;

// ============================================================================
// Boolean constructor builtins
// ============================================================================

/// ToBoolean then return boolean primitive (function call) or
/// a Boolean wrapper object (constructor call).
fn void builtin_boolean(BuiltinContext* ctx) {
    bool b;
    if (ctx.argc > 0) {
        b = builtin_to_boolean(&ctx.regs[ctx.base_reg]);
    } else {
        b = false;
    }

    if (ctx.is_constructor) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        (*obj.extra_ptr()).prim.primitive_value.set_boolean(b);
        ctx.result.set_object(obj);
    } else {
        ctx.result.set_boolean(b);
    }
}

/// Boolean.prototype.toString — returns "true" or "false"
fn void builtin_boolean_proto_toString(BuiltinContext* ctx) {
    // 'this' is at base_reg - 1
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    bool b = false;
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.BOOLEAN &&
            (*obj.extra_ptr()).prim.primitive_value.is_boolean()) {
            b = (*obj.extra_ptr()).prim.primitive_value.get_boolean();
        }
    } else if (this_val.is_boolean()) {
        b = this_val.get_boolean();
    }
    HString* s = builtin_intern_string(ctx.heap, b ? "true" : "false");
    ctx.result.set_string(s);
}

fn void builtin_boolean_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.BOOLEAN &&
            (*obj.extra_ptr()).prim.primitive_value.is_boolean()) {
            ctx.result.set_boolean((*obj.extra_ptr()).prim.primitive_value.get_boolean());
            return;
        }
    } else if (this_val.is_boolean()) {
        ctx.result.set_boolean(this_val.get_boolean());
        return;
    }
    ctx.result.set_undefined();
}
fn bool register_boolean_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Boolean.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.BOOLEAN);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    heap.bool_proto = proto;

    // Set .constructor to Boolean lightfunc
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_lightfunc((void*)(usz)BUILTIN_BOOLEAN);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Add .toString() method
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_BOOLEAN_PROTO_TOSTRING);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method
    HString* valueof_key = (HString*)heap.strs[heap::BuiltinStr.VALUE_OF];
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)BUILTIN_BOOLEAN_PROTO_VALUEOF);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC);

    // Register Boolean as a global constructor
    if (!register_simple_builtin(global_env, heap, "Boolean", BUILTIN_BOOLEAN)) return false;

    return true;
}
