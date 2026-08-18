/// Boolean constructor and Boolean.prototype methods.
module boomkat::builtins;
import boomkat::types;
import boomkat::env;
import boomkat::hstring;

import boomkat::heap;
import boomkat::hobject;

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
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.bool_proto);
        (*obj.extra_ptr()).prim.primitive_value.set_boolean(b);
        ctx.result.set_object(obj);
    } else {
        ctx.result.set_boolean(b);
    }
}

/// Boolean.prototype.toString, returns "true" or "false"
/// ES2015 §15.6.4.2: throws TypeError if `this` is not a Boolean or Boolean wrapper.
fn void builtin_boolean_proto_toString(BuiltinContext* ctx) {
    // 'this' is at base_reg - 1
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    bool b = false;
    bool found = false;
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.BOOLEAN &&
            (*obj.extra_ptr()).prim.primitive_value.is_boolean()) {
            b = (*obj.extra_ptr()).prim.primitive_value.get_boolean();
            found = true;
        }
    } else if (this_val.is_boolean()) {
        b = this_val.get_boolean();
        found = true;
    }
    if (!found) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Boolean.prototype.toString called on incompatible value");
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, b ? "true" : "false");
    ctx.result.set_string(s);
}

/// Boolean.prototype.valueOf, ES2015 §15.6.4.3: throws TypeError if `this`
/// is not a Boolean or Boolean wrapper object.
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
    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Boolean.prototype.valueOf called on incompatible value");
}
fn bool register_boolean_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Boolean.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.BOOLEAN);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    // ES5 §15.6.4: Boolean.prototype has [[PrimitiveValue]] = false
    (*proto.extra_ptr()).prim.primitive_value.set_boolean(false);
    heap.bool_proto = proto;

    // Add .toString() method
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)Builtin.BOOLEAN_PROTO_TOSTRING.ordinal);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC, heap);

    // Add .valueOf() method
    HString* valueof_key = (HString*)heap.strs[heap::BuiltinStr.VALUE_OF];
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)Builtin.BOOLEAN_PROTO_VALUEOF.ordinal);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC, heap);

    // Register Boolean as a proper HObject constructor (not a lightfunc).
    // Needs own "prototype" property (NWC) for S15.6.3_A1 and S15.6.3.1_A3.
    // [[Prototype]] is left null here; the post-init loop in core.c3 sets it
    // to Function.prototype (satisfying S15.6.3_A2).
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch e2 = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.BOOLEAN.ordinal;

    // Own "prototype" property (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    // Wire Boolean.prototype.constructor → Boolean ctor HObject
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal ctor_tv;
    ctor_tv.set_object(ctor);
    proto.put_prop(constructor_key, ctor_tv, hobject::PROP_FLAGS_WC, heap);

    // Set .name and .length
    set_func_ctor_name_length(ctor, heap, "Boolean", 1);

    // Register in global environment
    HString* key = heap.str_intern("Boolean");
    if (key == null) return false;
    TVal val;
    val.set_object(ctor);
    env::env_declare_nonenum(global_env, key, val);

    return true;
}
