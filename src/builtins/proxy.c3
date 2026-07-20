/// Proxy exotic object — ES2020 §10.5.
///
/// Implements the Proxy constructor, Proxy.revocable, and the essential
/// internal methods (MOP operations) with their trap-result invariant
/// validation.  The "trap absent" default forwards each operation to the
/// [[ProxyTarget]] using the ordinary semantics (the Reflect.* operations,
/// hand-rolled here — the JS-visible Reflect global stays out of scope).
///
/// Error reporting: these functions are callable both from builtins (via
/// BuiltinContext) and directly from the VM opcode handlers, so errors are
/// signalled through heap.has_error / heap.error_value (the same channel
/// call_fn uses for exceptions thrown inside JS callbacks).  Every proxy_mop_*
/// function returns false when an error is pending.
module duktape::builtins;
import duktape::types;
import std::math;
import duktape::hstring;
import duktape::env;
import std::io;

import duktape::heap;
import duktape::hobject;
import duktape::vm;

// ============================================================================
// Storage accessors
// ============================================================================

fn HObject* proxy_target(HObject* p)  @inline { return (*p.extra_ptr()).proxy.target; }
fn HObject* proxy_handler(HObject* p) @inline { return (*p.extra_ptr()).proxy.handler; }

/// Hidden own-property key on a revoker function that points back at its proxy.
/// 0xFF-prefixed so it is treated as a symbol (invisible to string-key paths).
const char[] PROXY_REVOKE_SLOT = "\xFFproxyRevokeSlot";

// ============================================================================
// Error helper — heap-level TypeError (usable without a BuiltinContext)
// ============================================================================

fn void proxy_throw_type(Heap* heap, char[] msg) {
    heap.has_error = true;
    HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch e = err_raw) {
        TVal undef; undef.set_undefined();
        heap.tval_copy_ref(&heap.error_value, &undef);
        return;
    }
    HObject* err = err_raw;
    err.prototype = heap.type_err_proto;
    HString* msg_str = builtin_intern_string(heap, msg);
    if (msg_str != null) {
        TVal msg_val; msg_val.set_string(msg_str);
        err.put_prop(builtin_intern_string(heap, "message"), msg_val, hobject::PROP_FLAGS_WC);
    }
    TVal err_tv; err_tv.set_object(err);
    heap.tval_copy_ref(&heap.error_value, &err_tv);
}

// ============================================================================
// Property descriptor record (with per-field presence, for partial descriptors)
// ============================================================================

struct ProxyDesc {
    bool found;             // descriptor exists at all
    bool has_value;
    bool has_writable;
    bool has_get;
    bool has_set;
    bool has_enumerable;
    bool has_configurable;
    bool writable;
    bool enumerable;
    bool configurable;
    TVal value;
    TVal getter;            // undefined when absent
    TVal setter;
}

fn bool ProxyDesc.is_accessor_desc(&self) @inline { return self.has_get || self.has_set; }
fn bool ProxyDesc.is_data_desc(&self)     @inline { return self.has_value || self.has_writable; }

/// CompletePropertyDescriptor (§6.2.5.6): fill absent fields with defaults.
fn void ProxyDesc.complete(&self) {
    if (self.is_accessor_desc()) {
        if (!self.has_get) { self.getter.set_undefined(); self.has_get = true; }
        if (!self.has_set) { self.setter.set_undefined(); self.has_set = true; }
    } else {
        if (!self.has_value) { self.value.set_undefined(); self.has_value = true; }
        if (!self.has_writable) { self.writable = false; self.has_writable = true; }
    }
    if (!self.has_enumerable)   { self.enumerable = false;   self.has_enumerable = true; }
    if (!self.has_configurable) { self.configurable = false; self.has_configurable = true; }
}

/// Ordinary own-property lookup into a ProxyDesc (no proxy recursion here —
/// callers that may see a proxy use own_property_desc below).
fn void ordinary_own_desc(Heap* heap, HObject* obj, HString* key, ProxyDesc* out) {
    *out = (ProxyDesc){};
    // Integer-Indexed exotic [[GetOwnProperty]] (ES2022 §10.4.5.1): canonical
    // numeric index keys never live in the property table — bypass it entirely.
    if (is_typed_array_class(obj.get_class())) {
        double num;
        if (ta_key_numeric_index(heap, key, &num)) {
            ta_own_index_desc(heap, obj, num, out);
            return;
        }
    }
    int idx = obj.find_prop_idx((void*)key);
    if (idx >= 0) {
        hobject::PropFlags f = obj.get_prop_flags((uint)idx);
        out.found = true;
        out.enumerable = f.enumerable;   out.has_enumerable = true;
        out.configurable = f.configurable; out.has_configurable = true;
        if (f.is_accessor) {
            TVal slot = obj.prop_values()[idx];
            out.getter = hobject::hobject_access_getter(slot); out.has_get = true;
            out.setter = hobject::hobject_access_setter(slot); out.has_set = true;
        } else {
            out.value = obj.prop_values()[idx]; out.has_value = true;
            out.writable = f.writable; out.has_writable = true;
        }
        return;
    }
    // Dense array part: elements are {writable, enumerable, configurable} data props.
    TVal dense;
    if (obj.dense_arridx_lookup((void*)key, &dense)) {
        out.found = true;
        out.has_value = true;    out.value = dense;
        out.has_writable = true; out.writable = true;
        out.has_enumerable = true; out.enumerable = true;
        out.has_configurable = true; out.configurable = true;
        return;
    }
    // ARRAY exotic "length" (writable, non-enumerable, non-configurable).
    if (obj.get_class() == hobject::ObjClass.ARRAY && key.equals("length")) {
        out.found = true;
        out.has_value = true; out.value.set_fastint((long)*obj.array_len_ptr());
        out.has_writable = true; out.writable = true;
        out.has_enumerable = true;
        out.has_configurable = true;
        return;
    }
    // STRING exotic: lazily-materialised character indices (§10.4.3.5).
    if (obj.flags.exotic_stringobj && !key.is_symbol() && key.is_arridx()
        && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        uint ci = key.array_index();
        if (prim != null && ci < prim.char_length()) {
            uint cp = prim.char_at(ci);
            char[4] cbuf;
            uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
            HString* ch = heap.str_intern(cbuf[:cblen]);
            if (ch != null) {
                out.found = true;
                out.has_value = true; out.value.set_string(ch);
                out.has_writable = true;
                out.has_enumerable = true; out.enumerable = true;
                out.has_configurable = true;
            }
        }
    }
}

/// Own-property descriptor with proxy recursion ([[GetOwnProperty]]).
fn bool own_property_desc(void* vm, Heap* heap, HObject* obj, HString* key, ProxyDesc* out) {
    if (obj.flags.exotic_proxyobj) {
        return proxy_mop_get_own(vm, heap, obj, key, out);
    }
    ordinary_own_desc(heap, obj, key, out);
    return true;
}

/// [[IsExtensible]] with proxy recursion.
fn bool object_is_extensible(void* vm, Heap* heap, HObject* obj, bool* out) {
    if (obj.flags.exotic_proxyobj) {
        return proxy_mop_is_extensible(vm, heap, obj, out);
    }
    *out = obj.flags.extensible;
    return true;
}

/// [[GetPrototypeOf]] with proxy recursion. Writes object-or-null TVal.
fn bool object_get_proto(void* vm, Heap* heap, HObject* obj, TVal* out) {
    if (obj.flags.exotic_proxyobj) {
        return proxy_mop_get_proto(vm, heap, obj, out);
    }
    if (obj.prototype != null) {
        out.set_object(obj.prototype);
    } else {
        out.set_null();
    }
    return true;
}

/// Transfer a pending heap-level proxy error into a BuiltinContext throw.
/// Returns false when an error was pending (caller should bail out).
fn bool proxy_ctx_ok(BuiltinContext* ctx) {
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        ctx.result.set_undefined();
        return false;
    }
    return true;
}

// ============================================================================
// Callability check for TVals
// ============================================================================

fn bool tval_is_callable(TVal v) {
    if (v.is_lightfunc()) return true;
    if (v.is_object()) {
        HObject* o = (HObject*)v.get_heapptr();
        return o != null && o.is_callable();
    }
    return false;
}

// ============================================================================
// Full JS [[Get]] with receiver (OrdinaryGet + proxy recursion + accessors)
// ============================================================================

fn bool js_get_with_receiver(void* vm, Heap* heap, HObject* obj, HString* key, TVal receiver, TVal* out) {
    // Integer-Indexed exotic [[Get]] (ES2022 §10.4.5.8): canonical numeric
    // index keys never walk the prototype chain.
    if (is_typed_array_class(obj.get_class())) {
        double num;
        if (ta_key_numeric_index(heap, key, &num)) {
            ProxyDesc d;
            ta_own_index_desc(heap, obj, num, &d);
            *out = d.found ? d.value : (TVal){};
            if (!d.found) out.set_undefined();
            return true;
        }
    }
    HObject* cur = obj;
    uint depth = 0;
    while (cur != null && depth < 256) {
        if (cur.flags.exotic_proxyobj) {
            return proxy_mop_get(vm, heap, cur, key, receiver, out);
        }
        ProxyDesc d;
        ordinary_own_desc(heap, cur, key, &d);
        if (d.found) {
            if (d.is_accessor_desc()) {
                if (!tval_is_callable(d.getter)) { out.set_undefined(); return true; }
                if (heap.call_fn == null) { out.set_undefined(); return true; }
                *out = heap.call_fn(vm, d.getter, null, 0, receiver);
                return !heap.has_error;
            }
            *out = d.value;
            return true;
        }
        cur = cur.prototype;
        depth++;
    }
    out.set_undefined();
    return true;
}

/// Convenience: [[Get]] where the receiver is the object itself.
fn bool js_get(void* vm, Heap* heap, HObject* obj, HString* key, TVal* out) {
    TVal recv; recv.set_object(obj);
    return js_get_with_receiver(vm, heap, obj, key, recv, out);
}

// ============================================================================
// Full JS [[Set]] with receiver (OrdinarySetWithOwnDescriptor + proxy recursion)
// ============================================================================

fn bool js_set_with_receiver(void* vm, Heap* heap, HObject* obj, HString* key, TVal val, TVal receiver, bool* res) {
    // Integer-Indexed exotic [[Set]] (ES2022 §10.4.5.10): canonical numeric
    // index keys bypass OrdinarySet entirely.
    if (is_typed_array_class(obj.get_class())) {
        double num;
        if (ta_key_numeric_index(heap, key, &num)) {
            bool same_recv = receiver.is_object() && (HObject*)receiver.get_heapptr() == obj;
            if (same_recv) {
                BuiltinContext conv_ctx;
                conv_ctx.vm = vm;
                conv_ctx.heap = heap;
                conv_ctx.should_throw = false;
                ta_integer_indexed_element_set(&conv_ctx, obj, num, val);
                if (conv_ctx.should_throw) {
                    heap.has_error = true;
                    heap.tval_copy_ref(&heap.error_value, &conv_ctx.throw_value);
                    return false;
                }
                *res = true;
                return true;
            }
            if (!ta_is_valid_integer_index(obj, num)) { *res = true; return true; }
            // Valid index but receiver differs from O: falls through to
            // OrdinarySet below (receiver gets its own data property).
        }
    }
    HObject* cur = obj;
    uint depth = 0;
    while (cur != null && depth < 256) {
        if (cur.flags.exotic_proxyobj) {
            return proxy_mop_set(vm, heap, cur, key, val, receiver, res);
        }
        // A TypedArray encountered while walking up the prototype chain
        // (cur != obj) has its own exotic [[Set]] — OrdinarySetWithOwnDescriptor
        // recurses into parent.[[Set]](P, V, Receiver) rather than treating it
        // as a flat OrdinaryGetOwnProperty lookup (ES2024 §9.1.9.2 step 2.b).
        if (cur != obj && is_typed_array_class(cur.get_class())) {
            return js_set_with_receiver(vm, heap, cur, key, val, receiver, res);
        }
        ProxyDesc d;
        ordinary_own_desc(heap, cur, key, &d);
        if (d.found) {
            if (d.is_accessor_desc()) {
                if (!tval_is_callable(d.setter)) { *res = false; return true; }
                if (heap.call_fn == null) { *res = false; return true; }
                TVal[1] args; args[0] = val;
                heap.call_fn(vm, d.setter, &args[0], 1, receiver);
                if (heap.has_error) return false;
                *res = true;
                return true;
            }
            if (!d.writable) { *res = false; return true; }
            break;  // writable data prop found — define on receiver below
        }
        cur = cur.prototype;
        depth++;
    }
    // CreateDataProperty / set existing data prop on the receiver
    // (OrdinarySet §10.1.9.2 steps 4-9).
    if (!receiver.is_object()) { *res = false; return true; }
    HObject* recv_obj = (HObject*)receiver.get_heapptr();
    if (recv_obj.flags.exotic_proxyobj) {
        // Step 4: existingDescriptor = Receiver.[[GetOwnProperty]](P)
        ProxyDesc existing;
        if (!proxy_mop_get_own(vm, heap, recv_obj, key, &existing)) return false;
        ProxyDesc nd = {};
        nd.found = true;
        nd.has_value = true; nd.value = val;
        if (existing.found) {
            // Step 5-7: reject if accessor or non-writable; else [[Define]]({value}).
            if (existing.is_accessor_desc() || !existing.writable) { *res = false; return true; }
            nd.has_writable = true; nd.writable = existing.writable;
            nd.has_enumerable = true; nd.enumerable = existing.enumerable;
            nd.has_configurable = true; nd.configurable = existing.configurable;
        } else {
            // Step 8: CreateDataProperty — full WEC descriptor.
            nd.has_writable = true; nd.writable = true;
            nd.has_enumerable = true; nd.enumerable = true;
            nd.has_configurable = true; nd.configurable = true;
        }
        return proxy_mop_define(vm, heap, recv_obj, key, &nd, res);
    }
    // Integer-Indexed exotic receiver: [[DefineOwnProperty]]({value}) on a
    // TypedArray routes through IntegerIndexedElementSet, not put_prop — and
    // an out-of-bounds numeric index simply fails rather than falling back
    // to CreateDataProperty.
    if (is_typed_array_class(recv_obj.get_class())) {
        double rnum;
        if (ta_key_numeric_index(heap, key, &rnum)) {
            if (!ta_is_valid_integer_index(recv_obj, rnum)) { *res = false; return true; }
            BuiltinContext conv_ctx;
            conv_ctx.vm = vm;
            conv_ctx.heap = heap;
            conv_ctx.should_throw = false;
            ta_integer_indexed_element_set(&conv_ctx, recv_obj, rnum, val);
            if (conv_ctx.should_throw) {
                heap.has_error = true;
                heap.tval_copy_ref(&heap.error_value, &conv_ctx.throw_value);
                return false;
            }
            *res = true;
            return true;
        }
    }
    ProxyDesc existing;
    ordinary_own_desc(heap, recv_obj, key, &existing);
    if (existing.found) {
        if (existing.is_accessor_desc() || !existing.writable) { *res = false; return true; }
        hobject::PropFlags pf = {
            .writable = existing.writable,
            .enumerable = existing.enumerable,
            .configurable = existing.configurable,
        };
        *res = recv_obj.put_prop((void*)key, val, pf);
        return true;
    }
    if (!recv_obj.flags.extensible) { *res = false; return true; }
    *res = recv_obj.put_prop((void*)key, val, hobject::PROP_FLAGS_WEC);
    return true;
}

// ============================================================================
// [[HasProperty]] (chain walk + proxy recursion)
// ============================================================================

fn bool js_has_property(void* vm, Heap* heap, HObject* obj, HString* key, bool* out) {
    // Integer-Indexed exotic [[HasProperty]] (ES2022 §10.4.5.2): a canonical
    // numeric index key never falls through to OrdinaryHasProperty / the
    // prototype chain, whether or not it is a valid in-bounds index.
    if (is_typed_array_class(obj.get_class())) {
        double num;
        if (ta_key_numeric_index(heap, key, &num)) {
            *out = ta_is_valid_integer_index(obj, num);
            return true;
        }
    }
    HObject* cur = obj;
    uint depth = 0;
    while (cur != null && depth < 256) {
        if (cur.flags.exotic_proxyobj) {
            return proxy_mop_has(vm, heap, cur, key, out);
        }
        ProxyDesc d;
        ordinary_own_desc(heap, cur, key, &d);
        if (d.found) { *out = true; return true; }
        cur = cur.prototype;
        depth++;
    }
    *out = false;
    return true;
}

// ============================================================================
// Trap lookup — GetMethod(handler, name)
// ============================================================================

/// Result: 0 = error pending, 1 = no trap (forward to target), 2 = trap found.
fn int proxy_find_trap(void* vm, Heap* heap, HObject* proxy, char[] name,
                       TVal* trap_out, HObject** target_out, HObject** handler_out) {
    HObject* handler = proxy_handler(proxy);
    HObject* target = proxy_target(proxy);
    if (handler == null || target == null) {
        char[types::ERROR_MSG_BUF] buf;
        int len = (int)(io::bprintf(&buf,
            "Cannot perform '%s' on a proxy that has been revoked", (String)name) ?? buf[:0]).len;
        char[] slice = (len > 0 && len < types::ERROR_MSG_BUF) ? buf[:len] : buf[:0];
        proxy_throw_type(heap, slice);
        return 0;
    }
    *target_out = target;
    *handler_out = handler;
    HString* key = builtin_intern_string(heap, name);
    if (key == null) { proxy_throw_type(heap, "out of memory"); return 0; }
    TVal trap;
    if (!js_get(vm, heap, handler, key, &trap)) return 0;
    if (trap.is_undefined() || trap.is_null()) return 1;
    if (!tval_is_callable(trap)) {
        char[types::ERROR_MSG_BUF] buf;
        int len = (int)(io::bprintf(&buf,
            "'%s' trap is not a function", (String)name) ?? buf[:0]).len;
        char[] slice = (len > 0 && len < types::ERROR_MSG_BUF) ? buf[:len] : buf[:0];
        proxy_throw_type(heap, slice);
        return 0;
    }
    *trap_out = trap;
    return 2;
}

/// Call a trap; returns false when the trap threw.
fn bool proxy_call_trap(void* vm, Heap* heap, TVal trap, HObject* handler,
                        TVal* args, uint nargs, TVal* out) {
    if (heap.call_fn == null) { proxy_throw_type(heap, "no VM call context"); return false; }
    TVal handler_tv; handler_tv.set_object(handler);
    *out = heap.call_fn(vm, trap, args, nargs, handler_tv);
    return !heap.has_error;
}

// ============================================================================
// [[Get]] — trap "get" (§10.5.8)
// ============================================================================

fn bool proxy_mop_get(void* vm, Heap* heap, HObject* proxy, HString* key, TVal receiver, TVal* out) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "get", &trap, &target, &handler);
    if (t == 0) return false;
    if (t == 1) return js_get_with_receiver(vm, heap, target, key, receiver, out);

    TVal[3] args;
    args[0].set_object(target);
    args[1].set_string(key);
    args[2] = receiver;
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 3, &result)) return false;

    ProxyDesc td;
    if (!own_property_desc(vm, heap, target, key, &td)) return false;
    if (td.found && !td.configurable) {
        if (td.is_data_desc() && !td.writable && !same_value(result, td.value)) {
            proxy_throw_type(heap, "'get' on proxy: property is a non-configurable non-writable data property whose value differs from the trap result");
            return false;
        }
        if (td.is_accessor_desc() && td.getter.is_undefined() && !result.is_undefined()) {
            proxy_throw_type(heap, "'get' on proxy: property is a non-configurable accessor without a getter, but the trap did not return undefined");
            return false;
        }
    }
    *out = result;
    return true;
}

// ============================================================================
// [[Set]] — trap "set" (§10.5.9)
// ============================================================================

fn bool proxy_mop_set(void* vm, Heap* heap, HObject* proxy, HString* key, TVal val, TVal receiver, bool* res) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "set", &trap, &target, &handler);
    if (t == 0) return false;
    if (t == 1) return js_set_with_receiver(vm, heap, target, key, val, receiver, res);

    TVal[4] args;
    args[0].set_object(target);
    args[1].set_string(key);
    args[2] = val;
    args[3] = receiver;
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 4, &result)) return false;
    if (!builtin_to_boolean(&result)) { *res = false; return true; }

    ProxyDesc td;
    if (!own_property_desc(vm, heap, target, key, &td)) return false;
    if (td.found && !td.configurable) {
        if (td.is_data_desc() && !td.writable && !same_value(val, td.value)) {
            proxy_throw_type(heap, "'set' on proxy: trap returned truish for a non-configurable non-writable data property with a different value");
            return false;
        }
        if (td.is_accessor_desc() && td.setter.is_undefined()) {
            proxy_throw_type(heap, "'set' on proxy: trap returned truish for a non-configurable accessor property without a setter");
            return false;
        }
    }
    *res = true;
    return true;
}

// ============================================================================
// [[Has]] — trap "has" (§10.5.7)
// ============================================================================

fn bool proxy_mop_has(void* vm, Heap* heap, HObject* proxy, HString* key, bool* out) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "has", &trap, &target, &handler);
    if (t == 0) return false;
    if (t == 1) return js_has_property(vm, heap, target, key, out);

    TVal[2] args;
    args[0].set_object(target);
    args[1].set_string(key);
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 2, &result)) return false;
    bool b = builtin_to_boolean(&result);
    if (!b) {
        ProxyDesc td;
        if (!own_property_desc(vm, heap, target, key, &td)) return false;
        if (td.found) {
            if (!td.configurable) {
                proxy_throw_type(heap, "'has' on proxy: trap returned falsish for a non-configurable own property");
                return false;
            }
            bool ext;
            if (!object_is_extensible(vm, heap, target, &ext)) return false;
            if (!ext) {
                proxy_throw_type(heap, "'has' on proxy: trap returned falsish for an own property of a non-extensible target");
                return false;
            }
        }
    }
    *out = b;
    return true;
}

// ============================================================================
// [[Delete]] — trap "deleteProperty" (§10.5.10)
// ============================================================================

fn bool proxy_mop_delete(void* vm, Heap* heap, HObject* proxy, HString* key, bool* out) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "deleteProperty", &trap, &target, &handler);
    if (t == 0) return false;
    if (t == 1) {
        if (target.flags.exotic_proxyobj) {
            return proxy_mop_delete(vm, heap, target, key, out);
        }
        *out = target.es_delete_prop((void*)key);
        return true;
    }

    TVal[2] args;
    args[0].set_object(target);
    args[1].set_string(key);
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 2, &result)) return false;
    if (!builtin_to_boolean(&result)) { *out = false; return true; }

    ProxyDesc td;
    if (!own_property_desc(vm, heap, target, key, &td)) return false;
    if (!td.found) { *out = true; return true; }
    if (!td.configurable) {
        proxy_throw_type(heap, "'deleteProperty' on proxy: trap returned truish for a non-configurable own property");
        return false;
    }
    bool ext;
    if (!object_is_extensible(vm, heap, target, &ext)) return false;
    if (!ext) {
        proxy_throw_type(heap, "'deleteProperty' on proxy: trap returned truish for an own property of a non-extensible target");
        return false;
    }
    *out = true;
    return true;
}

// ============================================================================
// Descriptor object <-> ProxyDesc conversion
// ============================================================================

/// FromPropertyDescriptor: build a JS descriptor object from a ProxyDesc
/// (only present fields are included).
fn HObject* proxy_desc_to_object(Heap* heap, ProxyDesc* d) {
    HObject*? raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch e = raw) return null;
    HObject* obj = raw;
    obj.prototype = heap.object_proto;
    TVal b;
    if (d.has_value) {
        obj.put_prop(builtin_intern_string(heap, "value"), d.value, hobject::PROP_FLAGS_WEC);
    }
    if (d.has_writable) {
        b.set_boolean(d.writable);
        obj.put_prop(builtin_intern_string(heap, "writable"), b, hobject::PROP_FLAGS_WEC);
    }
    if (d.has_get) {
        obj.put_prop(builtin_intern_string(heap, "get"), d.getter, hobject::PROP_FLAGS_WEC);
    }
    if (d.has_set) {
        obj.put_prop(builtin_intern_string(heap, "set"), d.setter, hobject::PROP_FLAGS_WEC);
    }
    if (d.has_enumerable) {
        b.set_boolean(d.enumerable);
        obj.put_prop(builtin_intern_string(heap, "enumerable"), b, hobject::PROP_FLAGS_WEC);
    }
    if (d.has_configurable) {
        b.set_boolean(d.configurable);
        obj.put_prop(builtin_intern_string(heap, "configurable"), b, hobject::PROP_FLAGS_WEC);
    }
    return obj;
}

/// ToPropertyDescriptor (§6.2.5.5) on a trap result object.
fn bool proxy_object_to_desc(void* vm, Heap* heap, HObject* obj, ProxyDesc* out) {
    *out = (ProxyDesc){};
    out.found = true;
    bool present;
    TVal v;
    HString* k;

    k = builtin_intern_string(heap, "enumerable");
    if (!js_has_property(vm, heap, obj, k, &present)) return false;
    if (present) {
        if (!js_get(vm, heap, obj, k, &v)) return false;
        out.has_enumerable = true; out.enumerable = builtin_to_boolean(&v);
    }
    k = builtin_intern_string(heap, "configurable");
    if (!js_has_property(vm, heap, obj, k, &present)) return false;
    if (present) {
        if (!js_get(vm, heap, obj, k, &v)) return false;
        out.has_configurable = true; out.configurable = builtin_to_boolean(&v);
    }
    k = builtin_intern_string(heap, "value");
    if (!js_has_property(vm, heap, obj, k, &present)) return false;
    if (present) {
        if (!js_get(vm, heap, obj, k, &v)) return false;
        out.has_value = true; out.value = v;
    }
    k = builtin_intern_string(heap, "writable");
    if (!js_has_property(vm, heap, obj, k, &present)) return false;
    if (present) {
        if (!js_get(vm, heap, obj, k, &v)) return false;
        out.has_writable = true; out.writable = builtin_to_boolean(&v);
    }
    k = builtin_intern_string(heap, "get");
    if (!js_has_property(vm, heap, obj, k, &present)) return false;
    if (present) {
        if (!js_get(vm, heap, obj, k, &v)) return false;
        if (!v.is_undefined() && !tval_is_callable(v)) {
            proxy_throw_type(heap, "Getter must be a function");
            return false;
        }
        out.has_get = true; out.getter = v;
    } else {
        out.getter.set_undefined();
    }
    k = builtin_intern_string(heap, "set");
    if (!js_has_property(vm, heap, obj, k, &present)) return false;
    if (present) {
        if (!js_get(vm, heap, obj, k, &v)) return false;
        if (!v.is_undefined() && !tval_is_callable(v)) {
            proxy_throw_type(heap, "Setter must be a function");
            return false;
        }
        out.has_set = true; out.setter = v;
    } else {
        out.setter.set_undefined();
    }
    if ((out.has_get || out.has_set) && (out.has_value || out.has_writable)) {
        proxy_throw_type(heap, "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute");
        return false;
    }
    return true;
}

// ============================================================================
// IsCompatiblePropertyDescriptor (§10.1.6.2 via ValidateAndApply with no target)
// ============================================================================

fn bool proxy_desc_compatible(bool extensible, ProxyDesc* desc, ProxyDesc* current) {
    if (!current.found) return extensible;
    if (current.configurable) return true;
    // current is non-configurable from here on
    if (desc.has_configurable && desc.configurable) return false;
    if (desc.has_enumerable && desc.enumerable != current.enumerable) return false;
    bool desc_is_acc = desc.is_accessor_desc();
    bool desc_is_data = desc.is_data_desc();
    bool cur_is_acc = current.is_accessor_desc();
    if (desc_is_acc && !cur_is_acc) return false;
    if (desc_is_data && cur_is_acc) return false;
    if (cur_is_acc) {
        if (desc.has_get && !same_value(desc.getter, current.getter)) return false;
        if (desc.has_set && !same_value(desc.setter, current.setter)) return false;
    } else if (!current.writable) {
        if (desc.has_writable && desc.writable) return false;
        if (desc.has_value && !same_value(desc.value, current.value)) return false;
    }
    return true;
}

// ============================================================================
// Ordinary [[DefineOwnProperty]] (ValidateAndApplyPropertyDescriptor, applied)
// ============================================================================

fn bool ordinary_define_own(void* vm, Heap* heap, HObject* obj, HString* key, ProxyDesc* desc, bool* res) {
    // Integer-Indexed exotic [[DefineOwnProperty]] (ES2022 §10.4.5.3): canonical
    // numeric index keys bypass ValidateAndApplyPropertyDescriptor entirely.
    if (is_typed_array_class(obj.get_class())) {
        double num;
        if (ta_key_numeric_index(heap, key, &num)) {
            if (!ta_is_valid_integer_index(obj, num)
                || desc.is_accessor_desc()
                || (desc.has_configurable && !desc.configurable)
                || (desc.has_enumerable && !desc.enumerable)
                || (desc.has_writable && !desc.writable)) {
                *res = false;
                return true;
            }
            if (desc.has_value) {
                BuiltinContext conv_ctx;
                conv_ctx.vm = vm;
                conv_ctx.heap = heap;
                conv_ctx.should_throw = false;
                ta_integer_indexed_element_set(&conv_ctx, obj, num, desc.value);
                if (conv_ctx.should_throw) {
                    heap.has_error = true;
                    heap.tval_copy_ref(&heap.error_value, &conv_ctx.throw_value);
                    return false;
                }
            }
            *res = true;
            return true;
        }
    }
    ProxyDesc cur;
    ordinary_own_desc(heap, obj, key, &cur);
    bool ext = obj.flags.extensible;
    if (!proxy_desc_compatible(ext, desc, &cur)) { *res = false; return true; }
    if (!cur.found && !ext) { *res = false; return true; }

    // Merge: start from current (or defaults), overlay present fields.
    ProxyDesc merged = cur;
    if (!cur.found) {
        merged = *desc;
        merged.complete();
    } else {
        // Kind change resets the other kind's fields.
        if (desc.is_accessor_desc() && !cur.is_accessor_desc()) {
            merged = (ProxyDesc){};
            merged.found = true;
            merged.enumerable = cur.enumerable; merged.has_enumerable = true;
            merged.configurable = cur.configurable; merged.has_configurable = true;
            merged.getter.set_undefined(); merged.setter.set_undefined();
            merged.has_get = true; merged.has_set = true;
        } else if (desc.is_data_desc() && cur.is_accessor_desc()) {
            merged = (ProxyDesc){};
            merged.found = true;
            merged.enumerable = cur.enumerable; merged.has_enumerable = true;
            merged.configurable = cur.configurable; merged.has_configurable = true;
            merged.value.set_undefined(); merged.has_value = true;
            merged.writable = false; merged.has_writable = true;
        }
        if (desc.has_value)        { merged.value = desc.value; merged.has_value = true; }
        if (desc.has_writable)     { merged.writable = desc.writable; merged.has_writable = true; }
        if (desc.has_get)          { merged.getter = desc.getter; merged.has_get = true; }
        if (desc.has_set)          { merged.setter = desc.setter; merged.has_set = true; }
        if (desc.has_enumerable)   { merged.enumerable = desc.enumerable; }
        if (desc.has_configurable) { merged.configurable = desc.configurable; }
    }

    hobject::PropFlags pf = {
        .writable = merged.writable,
        .enumerable = merged.enumerable,
        .configurable = merged.configurable,
    };
    if (merged.is_accessor_desc()) {
        pf.is_accessor = true;
        pf.writable = false;
        TVal gs = hobject::hobject_create_accessors(heap, merged.getter, merged.setter);
        if (gs.is_undefined()) { *res = false; return true; }
        *res = obj.put_prop((void*)key, gs, pf);
    } else {
        *res = obj.put_prop((void*)key, merged.value, pf);
    }
    return true;
}

/// [[DefineOwnProperty]] with proxy recursion.
fn bool object_define_own(void* vm, Heap* heap, HObject* obj, HString* key, ProxyDesc* desc, bool* res) {
    if (obj.flags.exotic_proxyobj) {
        return proxy_mop_define(vm, heap, obj, key, desc, res);
    }
    return ordinary_define_own(vm, heap, obj, key, desc, res);
}

// ============================================================================
// [[GetOwnProperty]] — trap "getOwnPropertyDescriptor" (§10.5.5)
// ============================================================================

fn bool proxy_mop_get_own(void* vm, Heap* heap, HObject* proxy, HString* key, ProxyDesc* out) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "getOwnPropertyDescriptor", &trap, &target, &handler);
    if (t == 0) return false;
    if (t == 1) return own_property_desc(vm, heap, target, key, out);

    TVal[2] args;
    args[0].set_object(target);
    args[1].set_string(key);
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 2, &result)) return false;
    if (!result.is_object() && !result.is_undefined()) {
        proxy_throw_type(heap, "'getOwnPropertyDescriptor' on proxy: trap returned neither object nor undefined");
        return false;
    }

    ProxyDesc td;
    if (!own_property_desc(vm, heap, target, key, &td)) return false;
    bool ext;
    if (!object_is_extensible(vm, heap, target, &ext)) return false;

    if (result.is_undefined()) {
        if (td.found && !td.configurable) {
            proxy_throw_type(heap, "'getOwnPropertyDescriptor' on proxy: trap returned undefined for a non-configurable own property");
            return false;
        }
        if (td.found && !ext) {
            proxy_throw_type(heap, "'getOwnPropertyDescriptor' on proxy: trap returned undefined for an own property of a non-extensible target");
            return false;
        }
        *out = (ProxyDesc){};
        return true;
    }

    ProxyDesc rd;
    if (!proxy_object_to_desc(vm, heap, (HObject*)result.get_heapptr(), &rd)) return false;
    rd.complete();
    if (!proxy_desc_compatible(ext, &rd, &td)) {
        proxy_throw_type(heap, "'getOwnPropertyDescriptor' on proxy: trap returned a descriptor incompatible with the target's own property");
        return false;
    }
    if (!rd.configurable) {
        if (!td.found || td.configurable) {
            proxy_throw_type(heap, "'getOwnPropertyDescriptor' on proxy: trap reported non-configurability for a property that is configurable or absent on the target");
            return false;
        }
        if (rd.has_writable && !rd.writable && td.writable) {
            proxy_throw_type(heap, "'getOwnPropertyDescriptor' on proxy: trap reported non-configurable non-writable for a writable target property");
            return false;
        }
    }
    *out = rd;
    return true;
}

// ============================================================================
// [[DefineOwnProperty]] — trap "defineProperty" (§10.5.6)
// ============================================================================

fn bool proxy_mop_define(void* vm, Heap* heap, HObject* proxy, HString* key, ProxyDesc* desc, bool* res) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "defineProperty", &trap, &target, &handler);
    if (t == 0) return false;
    if (t == 1) return object_define_own(vm, heap, target, key, desc, res);

    HObject* desc_obj = proxy_desc_to_object(heap, desc);
    if (desc_obj == null) { proxy_throw_type(heap, "out of memory"); return false; }
    TVal[3] args;
    args[0].set_object(target);
    args[1].set_string(key);
    args[2].set_object(desc_obj);
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 3, &result)) return false;
    if (!builtin_to_boolean(&result)) { *res = false; return true; }

    ProxyDesc td;
    if (!own_property_desc(vm, heap, target, key, &td)) return false;
    bool ext;
    if (!object_is_extensible(vm, heap, target, &ext)) return false;
    bool setting_config_false = desc.has_configurable && !desc.configurable;

    if (!td.found) {
        if (!ext) {
            proxy_throw_type(heap, "'defineProperty' on proxy: trap returned truish for adding a property to a non-extensible target");
            return false;
        }
        if (setting_config_false) {
            proxy_throw_type(heap, "'defineProperty' on proxy: trap returned truish for defining a non-configurable property which is absent on the target");
            return false;
        }
    } else {
        if (!proxy_desc_compatible(ext, desc, &td)) {
            proxy_throw_type(heap, "'defineProperty' on proxy: trap returned truish for a descriptor incompatible with the target's existing property");
            return false;
        }
        if (setting_config_false && td.configurable) {
            proxy_throw_type(heap, "'defineProperty' on proxy: trap returned truish for defining a non-configurable property over a configurable target property");
            return false;
        }
        if (td.is_data_desc() && !td.configurable && td.writable
            && desc.has_writable && !desc.writable) {
            proxy_throw_type(heap, "'defineProperty' on proxy: trap returned truish for making a non-configurable writable property non-writable");
            return false;
        }
    }
    *res = true;
    return true;
}

// ============================================================================
// [[OwnPropertyKeys]] — trap "ownKeys" (§10.5.11)
// ============================================================================

/// Collect all own property keys of an ordinary object (dense array indices
/// first, then integer-index named props, then strings, then symbols) into a
/// heap-allocated HString* buffer. Returns count; caller frees *buf_out.
fn uint ordinary_own_keys(Heap* heap, HObject* obj, HString*** buf_out) {
    uint cap = obj.prop_count + obj.array_used + 4;
    HString** buf = (HString**)heap.alloc_func(heap.heap_udata, (usz)cap * (usz)void*::size);
    if (buf == null) { *buf_out = null; return 0; }
    uint n = 0;
    // STRING exotic: character indices are own properties.
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) {
            uint clen = prim.char_length();
            if (cap < clen + obj.prop_count + 4) {
                heap.free_func(heap.heap_udata, buf);
                cap = clen + obj.prop_count + 4;
                buf = (HString**)heap.alloc_func(heap.heap_udata, (usz)cap * (usz)void*::size);
                if (buf == null) { *buf_out = null; return 0; }
            }
            for (uint i = 0; i < clen && n < cap; i++) {
                HString* k = heap.int_to_hstring((long)i);
                if (k != null) buf[n++] = k;
            }
        }
    }
    // Dense array part (ascending; holes are undefined sentinels)
    if (obj.array_part() != null) {
        for (uint i = 0; i < obj.array_used && n < cap; i++) {
            if (!obj.array_part()[i].is_undefined()) {
                HString* k = heap.int_to_hstring((long)i);
                if (k != null) buf[n++] = k;
            }
        }
    }
    // Integer-index named props (ascending), merged after dense for simplicity
    for (uint i = 0; i < obj.prop_count && n < cap; i++) {
        HString* k = (HString*)obj.prop_key_at(i);
        if (k != null && k.is_arridx() && !k.is_symbol()) buf[n++] = k;
    }
    // Non-index strings (insertion order)
    for (uint i = 0; i < obj.prop_count && n < cap; i++) {
        HString* k = (HString*)obj.prop_key_at(i);
        if (k != null && !k.is_arridx() && !k.is_symbol()) buf[n++] = k;
    }
    // Symbols (insertion order)
    for (uint i = 0; i < obj.prop_count && n < cap; i++) {
        HString* k = (HString*)obj.prop_key_at(i);
        if (k != null && k.is_symbol()) {
            if (k.is_hidden()) continue;
            buf[n++] = k;
        }
    }
    *buf_out = buf;
    return n;
}

/// [[OwnPropertyKeys]]: writes a JS Array of keys to *arr_out.
fn bool proxy_mop_own_keys(void* vm, Heap* heap, HObject* proxy, HObject** arr_out) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "ownKeys", &trap, &target, &handler);
    if (t == 0) return false;

    if (t == 1) {
        if (target.flags.exotic_proxyobj) {
            return proxy_mop_own_keys(vm, heap, target, arr_out);
        }
        HString** keys;
        uint n = ordinary_own_keys(heap, target, &keys);
        HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch e = arr_raw) {
            if (keys != null) heap.free_func(heap.heap_udata, keys);
            proxy_throw_type(heap, "out of memory");
            return false;
        }
        HObject* arr = arr_raw;
        arr.prototype = heap.array_proto;
        for (uint i = 0; i < n; i++) {
            TVal kv; kv.set_string(keys[i]);
            array_set_elem(arr, i, kv, heap);
        }
        TVal len_tv; len_tv.set_fastint((long)n);
        arr.put_prop((void*)(HString*)heap.strs[heap::BuiltinStr.LENGTH], len_tv, hobject::PROP_FLAGS_WC);
        if (keys != null) heap.free_func(heap.heap_udata, keys);
        *arr_out = arr;
        return true;
    }

    TVal[1] args;
    args[0].set_object(target);
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 1, &result)) return false;
    if (!result.is_object()) {
        proxy_throw_type(heap, "'ownKeys' on proxy: trap returned a non-object");
        return false;
    }
    HObject* res_obj = (HObject*)result.get_heapptr();

    // CreateListFromArrayLike, string/symbol keys only, no duplicates.
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv;
    if (!js_get(vm, heap, res_obj, len_key, &len_tv)) return false;
    long len = 0;
    if (len_tv.is_fastint()) { len = len_tv.get_fastint(); }
    else if (len_tv.is_number()) { len = (long)len_tv.get_number(); }
    if (len < 0) len = 0;
    if (len > 0xFFFFFF) {
        proxy_throw_type(heap, "'ownKeys' on proxy: trap result is too long");
        return false;
    }
    uint n = (uint)len;
    HString** keys = (HString**)heap.alloc_func(heap.heap_udata, (usz)(n + 1) * (usz)void*::size);
    if (keys == null) { proxy_throw_type(heap, "out of memory"); return false; }
    for (uint i = 0; i < n; i++) {
        HString* ik = heap.int_to_hstring((long)i);
        TVal kv;
        if (ik == null || !js_get(vm, heap, res_obj, ik, &kv)) {
            heap.free_func(heap.heap_udata, keys);
            return false;
        }
        if (!kv.is_string()) {
            heap.free_func(heap.heap_udata, keys);
            proxy_throw_type(heap, "'ownKeys' on proxy: trap result must contain only strings and symbols");
            return false;
        }
        keys[i] = (HString*)kv.get_heapptr();
    }
    // Duplicate check (O(n^2); trap results are small in practice).
    for (uint i = 0; i < n; i++) {
        for (uint j = i + 1; j < n; j++) {
            if (keys[i] == keys[j]) {
                heap.free_func(heap.heap_udata, keys);
                proxy_throw_type(heap, "'ownKeys' on proxy: trap returned duplicate entries");
                return false;
            }
        }
    }

    bool ext;
    if (!object_is_extensible(vm, heap, target, &ext)) {
        heap.free_func(heap.heap_udata, keys);
        return false;
    }
    // Invariants against the target's own keys.
    HString** tkeys = null;
    uint tn = 0;
    if (target.flags.exotic_proxyobj) {
        // Target is itself a proxy: get its keys via its own [[OwnPropertyKeys]].
        HObject* tarr;
        if (!proxy_mop_own_keys(vm, heap, target, &tarr)) {
            heap.free_func(heap.heap_udata, keys);
            return false;
        }
        tn = tarr.array_used;
        tkeys = (HString**)heap.alloc_func(heap.heap_udata, (usz)(tn + 1) * (usz)void*::size);
        if (tkeys != null) {
            for (uint i = 0; i < tn; i++) {
                TVal el = tarr.array_part()[i];
                tkeys[i] = el.is_string() ? (HString*)el.get_heapptr() : null;
            }
        } else {
            tn = 0;
        }
    } else {
        tn = ordinary_own_keys(heap, target, &tkeys);
    }
    bool violation_nonconf = false;
    bool violation_missing = false;
    uint matched = 0;
    for (uint i = 0; i < tn; i++) {
        if (tkeys[i] == null) continue;
        bool in_result = false;
        for (uint j = 0; j < n; j++) {
            if (keys[j] == tkeys[i]) { in_result = true; break; }
        }
        if (in_result) { matched++; continue; }
        // Missing from trap result: fatal if non-configurable, or target non-extensible.
        ProxyDesc td;
        if (!own_property_desc(vm, heap, target, tkeys[i], &td)) {
            heap.free_func(heap.heap_udata, keys);
            if (tkeys != null) heap.free_func(heap.heap_udata, tkeys);
            return false;
        }
        if (td.found && !td.configurable) { violation_nonconf = true; }
        else { violation_missing = true; }
    }
    if (tkeys != null) heap.free_func(heap.heap_udata, tkeys);
    if (violation_nonconf) {
        heap.free_func(heap.heap_udata, keys);
        proxy_throw_type(heap, "'ownKeys' on proxy: trap result did not include all non-configurable own keys of the target");
        return false;
    }
    if (!ext && violation_missing) {
        heap.free_func(heap.heap_udata, keys);
        proxy_throw_type(heap, "'ownKeys' on proxy: trap result did not include all own keys of the non-extensible target");
        return false;
    }
    if (!ext && n != matched) {
        heap.free_func(heap.heap_udata, keys);
        proxy_throw_type(heap, "'ownKeys' on proxy: trap returned extra keys but the target is non-extensible");
        return false;
    }

    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch e = arr_raw) {
        heap.free_func(heap.heap_udata, keys);
        proxy_throw_type(heap, "out of memory");
        return false;
    }
    HObject* arr = arr_raw;
    arr.prototype = heap.array_proto;
    for (uint i = 0; i < n; i++) {
        TVal kv; kv.set_string(keys[i]);
        array_set_elem(arr, i, kv, heap);
    }
    TVal alen_tv; alen_tv.set_fastint((long)n);
    arr.put_prop((void*)(HString*)heap.strs[heap::BuiltinStr.LENGTH], alen_tv, hobject::PROP_FLAGS_WC);
    heap.free_func(heap.heap_udata, keys);
    *arr_out = arr;
    return true;
}

/// Own keys of a proxy filtered by kind and enumerability.
/// mode: 0 = enumerable string keys (Object.keys / for-in),
///       1 = all string keys (getOwnPropertyNames),
///       2 = symbol keys (getOwnPropertySymbols).
/// Returns keys in *buf_out (caller frees via heap.free_func) and the count.
fn bool proxy_filtered_own_keys(void* vm, Heap* heap, HObject* proxy, int mode,
                                HString*** buf_out, uint* count_out) {
    *buf_out = null;
    *count_out = 0;
    HObject* arr;
    if (!proxy_mop_own_keys(vm, heap, proxy, &arr)) return false;
    uint n = arr.array_used;
    HString** buf = (HString**)heap.alloc_func(heap.heap_udata, (usz)(n + 1) * (usz)void*::size);
    if (buf == null) { proxy_throw_type(heap, "out of memory"); return false; }
    uint out_n = 0;
    for (uint i = 0; i < n; i++) {
        TVal el = arr.array_part()[i];
        if (!el.is_string()) continue;
        HString* k = (HString*)el.get_heapptr();
        bool is_sym = k.is_symbol();
        if (mode == 2) {
            if (!is_sym) continue;
            if (k.is_hidden()) continue;
        } else {
            if (is_sym) continue;
        }
        if (mode == 0) {
            ProxyDesc d;
            if (!proxy_mop_get_own(vm, heap, proxy, k, &d)) {
                heap.free_func(heap.heap_udata, buf);
                return false;
            }
            if (!d.found || !d.enumerable) continue;
        }
        buf[out_n++] = k;
    }
    *buf_out = buf;
    *count_out = out_n;
    return true;
}

// ============================================================================
// [[GetPrototypeOf]] / [[SetPrototypeOf]] (§10.5.1 / §10.5.2)
// ============================================================================

fn bool proxy_mop_get_proto(void* vm, Heap* heap, HObject* proxy, TVal* out) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "getPrototypeOf", &trap, &target, &handler);
    if (t == 0) return false;
    if (t == 1) return object_get_proto(vm, heap, target, out);

    TVal[1] args;
    args[0].set_object(target);
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 1, &result)) return false;
    if (!result.is_object() && !result.is_null()) {
        proxy_throw_type(heap, "'getPrototypeOf' on proxy: trap returned neither object nor null");
        return false;
    }
    bool ext;
    if (!object_is_extensible(vm, heap, target, &ext)) return false;
    if (!ext) {
        TVal tproto;
        if (!object_get_proto(vm, heap, target, &tproto)) return false;
        if (!same_value(result, tproto)) {
            proxy_throw_type(heap, "'getPrototypeOf' on proxy: proxy target is non-extensible but the trap did not return its actual prototype");
            return false;
        }
    }
    *out = result;
    return true;
}

fn bool proxy_mop_set_proto(void* vm, Heap* heap, HObject* proxy, TVal proto, bool* res) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "setPrototypeOf", &trap, &target, &handler);
    if (t == 0) return false;
    if (t == 1) {
        if (target.flags.exotic_proxyobj) {
            return proxy_mop_set_proto(vm, heap, target, proto, res);
        }
        if (!target.flags.extensible) {
            TVal cur_proto;
            if (!object_get_proto(vm, heap, target, &cur_proto)) return false;
            *res = same_value(proto, cur_proto);
            return true;
        }
        HObject* new_proto = proto.is_object() ? (HObject*)proto.get_heapptr() : null;
        // OrdinarySetPrototypeOf cycle check (§10.1.2.1 step 8): reject a
        // prototype chain that would loop back to the target.
        HObject* cyc = new_proto;
        uint cdepth = 0;
        while (cyc != null && cdepth < 256) {
            if (cyc == target) { *res = false; return true; }
            if (cyc.flags.exotic_proxyobj) break;  // spec stops the walk at non-ordinary objects
            cyc = cyc.prototype;
            cdepth++;
        }
        target.prototype = new_proto;
        *res = true;
        return true;
    }

    TVal[2] args;
    args[0].set_object(target);
    args[1] = proto;
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 2, &result)) return false;
    if (!builtin_to_boolean(&result)) { *res = false; return true; }
    bool ext;
    if (!object_is_extensible(vm, heap, target, &ext)) return false;
    if (!ext) {
        TVal tproto;
        if (!object_get_proto(vm, heap, target, &tproto)) return false;
        if (!same_value(proto, tproto)) {
            proxy_throw_type(heap, "'setPrototypeOf' on proxy: trap returned truish for setting a different prototype on the non-extensible proxy target");
            return false;
        }
    }
    *res = true;
    return true;
}

// ============================================================================
// [[IsExtensible]] / [[PreventExtensions]] (§10.5.3 / §10.5.4)
// ============================================================================

fn bool proxy_mop_is_extensible(void* vm, Heap* heap, HObject* proxy, bool* out) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "isExtensible", &trap, &target, &handler);
    if (t == 0) return false;
    if (t == 1) return object_is_extensible(vm, heap, target, out);

    TVal[1] args;
    args[0].set_object(target);
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 1, &result)) return false;
    bool b = builtin_to_boolean(&result);
    bool ext;
    if (!object_is_extensible(vm, heap, target, &ext)) return false;
    if (b != ext) {
        proxy_throw_type(heap, "'isExtensible' on proxy: trap result does not reflect extensibility of proxy target");
        return false;
    }
    *out = b;
    return true;
}

fn bool proxy_mop_prevent_extensions(void* vm, Heap* heap, HObject* proxy, bool* res) {
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(vm, heap, proxy, "preventExtensions", &trap, &target, &handler);
    if (t == 0) return false;
    if (t == 1) {
        if (target.flags.exotic_proxyobj) {
            return proxy_mop_prevent_extensions(vm, heap, target, res);
        }
        target.flags.extensible = false;
        *res = true;
        return true;
    }

    TVal[1] args;
    args[0].set_object(target);
    TVal result;
    if (!proxy_call_trap(vm, heap, trap, handler, &args[0], 1, &result)) return false;
    if (!builtin_to_boolean(&result)) { *res = false; return true; }
    bool ext;
    if (!object_is_extensible(vm, heap, target, &ext)) return false;
    if (ext) {
        proxy_throw_type(heap, "'preventExtensions' on proxy: trap returned truish but the proxy target is extensible");
        return false;
    }
    *res = true;
    return true;
}

/// SetIntegrityLevel(O, level) — ES2015 §7.3.13 — for a Proxy target.
/// Routes [[PreventExtensions]] then [[DefineOwnProperty]] for every own key
/// through the MOP so a `defineProperty`/`preventExtensions` trap observes
/// the same partial descriptors an ordinary object walk would apply: data
/// properties get {writable:false} (frozen only) and every property gets
/// {configurable:false}; accessor properties only ever get {configurable:false}.
fn bool proxy_set_integrity_level(void* vm, Heap* heap, HObject* proxy, bool frozen) {
    bool pok;
    if (!proxy_mop_prevent_extensions(vm, heap, proxy, &pok)) return false;
    if (!pok) {
        proxy_throw_type(heap, "'preventExtensions' on proxy: trap returned falsish");
        return false;
    }

    HObject* karr;
    if (!proxy_mop_own_keys(vm, heap, proxy, &karr)) return false;
    for (uint i = 0; i < karr.array_used; i++) {
        TVal el = karr.array_part()[i];
        if (!el.is_string()) continue;
        HString* k = (HString*)el.get_heapptr();

        ProxyDesc desc = (ProxyDesc){};
        if (frozen) {
            ProxyDesc current;
            if (!proxy_mop_get_own(vm, heap, proxy, k, &current)) return false;
            if (!current.found) continue;
            if (current.is_data_desc()) {
                desc.has_writable = true;
                desc.writable = false;
            }
        }
        desc.has_configurable = true;
        desc.configurable = false;

        bool dok;
        if (!proxy_mop_define(vm, heap, proxy, k, &desc, &dok)) return false;
        if (!dok) {
            proxy_throw_type(heap, "'defineProperty' on proxy: trap returned falsish");
            return false;
        }
    }
    return true;
}

/// TestIntegrityLevel(O, level) — ES2015 §7.3.15 — for a Proxy.
/// The proxy MOP calls are required even when their traps are absent: in that
/// case proxy_mop_own_keys forwards to the target's [[OwnPropertyKeys]], while
/// [[GetOwnProperty]] still runs on the outer proxy for every forwarded key.
fn bool proxy_test_integrity_level(void* vm, Heap* heap, HObject* proxy,
                                   bool frozen, bool* out) {
    bool ext;
    if (!proxy_mop_is_extensible(vm, heap, proxy, &ext)) return false;
    if (ext) {
        *out = false;
        return true;
    }

    HObject* karr;
    if (!proxy_mop_own_keys(vm, heap, proxy, &karr)) return false;
    for (uint i = 0; i < karr.array_used; i++) {
        TVal el = karr.array_part()[i];
        if (!el.is_string()) continue;
        HString* k = (HString*)el.get_heapptr();

        ProxyDesc current;
        if (!proxy_mop_get_own(vm, heap, proxy, k, &current)) return false;
        if (!current.found) continue;
        if (current.configurable
            || (frozen && current.is_data_desc() && current.writable)) {
            *out = false;
            return true;
        }
    }

    *out = true;
    return true;
}

// ============================================================================
// IsArray recursion (§7.2.2) — a Proxy is an array iff its target is.
// ============================================================================

fn bool proxy_is_array(Heap* heap, HObject* obj, bool* out) {
    uint depth = 0;
    HObject* cur = obj;
    while (cur != null && cur.flags.exotic_proxyobj && depth < 256) {
        if (proxy_target(cur) == null) {
            proxy_throw_type(heap, "Cannot perform 'IsArray' on a proxy that has been revoked");
            return false;
        }
        cur = proxy_target(cur);
        depth++;
    }
    *out = cur != null && cur.get_class() == hobject::ObjClass.ARRAY;
    return true;
}

// ============================================================================
// Proxy constructor / Proxy.revocable / revoker / [[Call]]+[[Construct]]
// ============================================================================

fn HObject* proxy_create(BuiltinContext* ctx, TVal target_tv, TVal handler_tv) {
    // LIGHTFUNC is an internal compact representation for built-in function
    // objects (e.g. Object.prototype.hasOwnProperty, parseInt, eval). The
    // ProxyCreate spec accepts any Object as the target/handler; since
    // lightfuncs satisfy `typeof === "function"` and `IsCallable`, materialize
    // them into full callable HObjects before storing the proxy slots — same
    // pattern as Object.setPrototypeOf's lightfunc handling.
    if (target_tv.is_lightfunc()) {
        uint fn_idx = (uint)(usz)target_tv.get_heapptr();
        BuiltinMeta meta = builtin_get_metadata(fn_idx);
        HObject* target_obj = alloc_builtin_fn(ctx.heap, fn_idx, meta.name, meta.arity);
        if (target_obj == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "out of memory");
            return null;
        }
        if (ctx.vm != null) {
            target_obj.flags.constructable = vm::builtin_fn_is_constructor((Vm*)ctx.vm, fn_idx);
        }
        target_tv.set_object(target_obj);
    }
    if (handler_tv.is_lightfunc()) {
        uint fn_idx = (uint)(usz)handler_tv.get_heapptr();
        BuiltinMeta meta = builtin_get_metadata(fn_idx);
        HObject* handler_obj = alloc_builtin_fn(ctx.heap, fn_idx, meta.name, meta.arity);
        if (handler_obj == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "out of memory");
            return null;
        }
        if (ctx.vm != null) {
            handler_obj.flags.constructable = vm::builtin_fn_is_constructor((Vm*)ctx.vm, fn_idx);
        }
        handler_tv.set_object(handler_obj);
    }
    if (!target_tv.is_object() || !handler_tv.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot create proxy with a non-object as target or handler");
        return null;
    }
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.PROXY);
    if (catch e = raw) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "out of memory");
        return null;
    }
    HObject* p = raw;
    HObject* target = (HObject*)target_tv.get_heapptr();
    HObject* handler = (HObject*)handler_tv.get_heapptr();
    (*p.extra_ptr()).proxy.target = target;
    (*p.extra_ptr()).proxy.handler = handler;
    p.prototype = null;   // a proxy has no own [[Prototype]]; all MOP ops are intercepted
    // Mirror callability so `typeof` and the call dispatch route through the
    // proxy call builtin.
    if (target.is_callable()) {
        p.flags.callable = true;
        (*p.extra_ptr()).proxy.builtin_fn_index = (int)Builtin.PROXY_CALL.ordinal;
    }
    if (target.is_constructable()) {
        p.flags.constructable = true;
        (*p.extra_ptr()).proxy.builtin_fn_index = (int)Builtin.PROXY_CALL.ordinal;
    }
    return p;
}

fn void builtin_proxy(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Constructor Proxy requires 'new'");
        return;
    }
    TVal target_tv; target_tv.set_undefined();
    TVal handler_tv; handler_tv.set_undefined();
    if (ctx.argc >= 1) target_tv = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) handler_tv = ctx.regs[ctx.base_reg + 1];
    HObject* p = proxy_create(ctx, target_tv, handler_tv);
    if (p == null) return;
    ctx.result.set_object(p);
}

fn void builtin_proxy_revocable(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    TVal handler_tv; handler_tv.set_undefined();
    if (ctx.argc >= 1) target_tv = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) handler_tv = ctx.regs[ctx.base_reg + 1];
    HObject* p = proxy_create(ctx, target_tv, handler_tv);
    if (p == null) return;

    // Revoker function: a builtin FUNCTION carrying the proxy in a hidden slot.
    HObject*? fn_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch e = fn_raw) { ctx.result.set_undefined(); return; }
    HObject* revoker = fn_raw;
    (*revoker.extra_ptr()).func.builtin_fn_index = (int)Builtin.PROXY_REVOKE.ordinal;
    revoker.flags.callable = true;
    revoker.flags.constructable = false;
    revoker.prototype = ctx.heap.function_proto;
    // Own props in spec order: length (0), then name ("").
    TVal rl; rl.set_fastint(0);
    revoker.put_prop((void*)(HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH], rl, hobject::PROP_FLAGS_NWC);
    HString* empty_name = builtin_intern_string(ctx.heap, "");
    TVal rn; rn.set_string(empty_name);
    revoker.put_prop(builtin_intern_string(ctx.heap, "name"), rn, hobject::PROP_FLAGS_NWC);
    HString* slot_key = ctx.heap.str_intern(PROXY_REVOKE_SLOT);
    TVal p_tv; p_tv.set_object(p);
    revoker.put_prop(slot_key, p_tv, hobject::PROP_FLAGS_NWC);

    // Result: { proxy, revoke }
    HObject*? res_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch e2 = res_raw) { ctx.result.set_undefined(); return; }
    HObject* res = res_raw;
    res.prototype = ctx.heap.object_proto;
    TVal r_tv; r_tv.set_object(revoker);
    res.put_prop(builtin_intern_string(ctx.heap, "proxy"), p_tv, hobject::PROP_FLAGS_WEC);
    res.put_prop(builtin_intern_string(ctx.heap, "revoke"), r_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object(res);
}

fn void builtin_proxy_revoke(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    if (ctx.callee_obj == null) return;
    HString* slot_key = ctx.heap.str_intern(PROXY_REVOKE_SLOT);
    int idx = ctx.callee_obj.find_prop_idx((void*)slot_key);
    if (idx < 0) return;
    TVal p_tv = ctx.callee_obj.prop_values()[idx];
    if (!p_tv.is_object()) return;
    HObject* p = (HObject*)p_tv.get_heapptr();
    if (!p.flags.exotic_proxyobj) return;
    (*p.extra_ptr()).proxy.target = null;
    (*p.extra_ptr()).proxy.handler = null;
    // Mark the revoker as spent so a second call is a no-op.
    TVal undef; undef.set_undefined();
    ctx.callee_obj.put_prop((void*)slot_key, undef, hobject::PROP_FLAGS_NWC);
}

/// Proxy [[Call]] and [[Construct]] — dispatched through the ordinary builtin
/// call path (the proxy object's extra.proxy.builtin_fn_index points here and
/// ctx.callee_obj is the proxy itself).
fn void builtin_proxy_call(BuiltinContext* ctx) {
    HObject* p = ctx.callee_obj;
    if (p == null || !p.flags.exotic_proxyobj) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "proxy call on non-proxy");
        return;
    }
    Heap* heap = ctx.heap;
    char[] trap_name = ctx.is_constructor ? "construct" : "apply";
    TVal trap; HObject* target; HObject* handler;
    int t = proxy_find_trap(ctx.vm, heap, p, trap_name, &trap, &target, &handler);
    if (t == 0) {
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        ctx.result.set_undefined();
        return;
    }

    TVal target_tv; target_tv.set_object(target);

    if (t == 1) {
        // No trap: forward to the target.
        if (ctx.is_constructor) {
            if (heap.construct_fn == null) { ctx.result.set_undefined(); return; }
            // ES2020 §10.5.2 step 5: Construct(target, args, newTarget). newTarget
            // is whatever the caller supplied (Reflect.construct's third argument),
            // defaulting to the proxy itself (p) for ordinary `new P(...)` calls.
            // Before forwarding we must simulate GetPrototypeFromConstructor(p,
            // "%ObjectPrototype%")'s Get(p, "prototype") step, which triggers the
            // proxy's [[Get]] trap — if that trap revokes p, the subsequent
            // GetFunctionRealm(p) would throw (revoked proxy). We replicate that
            // check explicitly:
            HString* proto_key_str = builtin_intern_string(heap, "prototype");
            if (proto_key_str != null) {
                TVal proto_val; proto_val.set_undefined();
                if (!js_get(ctx.vm, heap, p, proto_key_str, &proto_val)) {
                    // js_get set heap.has_error
                    ctx.should_throw = true;
                    ctx.throw_value = heap.error_value;
                    heap.has_error = false;
                    ctx.result.set_undefined();
                    return;
                }
                // If prototype is not an Object, GetFunctionRealm(p) is called.
                // Per §7.3.22 step 4a: if p is a Proxy and its [[ProxyHandler]] is null, throw.
                if (!proto_val.is_object() || proto_val.get_heapptr() == null) {
                    if (proxy_handler(p) == null) {
                        builtin_throw(ctx, heap.type_err_proto,
                            "Cannot perform 'construct' on a proxy that has been revoked");
                        return;
                    }
                }
            }
            TVal fwd_new_target;
            if (ctx.new_target != null) { fwd_new_target.set_object(ctx.new_target); } else { fwd_new_target.set_object(p); }
            *ctx.result = heap.construct_fn(ctx.vm, target_tv, &ctx.regs[ctx.base_reg], ctx.argc, fwd_new_target);
        } else {
            if (heap.call_fn == null) { ctx.result.set_undefined(); return; }
            *ctx.result = heap.call_fn(ctx.vm, target_tv, &ctx.regs[ctx.base_reg], ctx.argc, ctx.this_val);
        }
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
        }
        return;
    }

    // Package the arguments into an array.
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch e = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = heap.array_proto;
    for (uint i = 0; i < ctx.argc; i++) {
        array_set_elem(arr, i, ctx.regs[ctx.base_reg + i], heap);
    }
    TVal alen; alen.set_fastint((long)ctx.argc);
    arr.put_prop((void*)(HString*)heap.strs[heap::BuiltinStr.LENGTH], alen, hobject::PROP_FLAGS_WC);
    TVal arr_tv; arr_tv.set_object(arr);

    TVal result;
    if (ctx.is_constructor) {
        TVal nt_tv;
        if (ctx.new_target != null) { nt_tv.set_object(ctx.new_target); } else { nt_tv.set_object(p); }
        TVal[3] args;
        args[0] = target_tv;
        args[1] = arr_tv;
        args[2] = nt_tv;
        if (!proxy_call_trap(ctx.vm, heap, trap, handler, &args[0], 3, &result)) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
        if (!result.is_object()) {
            builtin_throw(ctx, heap.type_err_proto, "'construct' on proxy: trap returned non-object");
            return;
        }
    } else {
        TVal[3] args;
        args[0] = target_tv;
        args[1] = ctx.this_val;
        args[2] = arr_tv;
        if (!proxy_call_trap(ctx.vm, heap, trap, handler, &args[0], 3, &result)) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
    }
    *ctx.result = result;
}

// ============================================================================
// Registration
// ============================================================================

fn bool register_proxy_constructor(EnvRecord* global_env, Heap* heap) {
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch e = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.PROXY.ordinal;
    ctor.prototype = heap.function_proto;

    TVal len_tv; len_tv.set_fastint(2);
    ctor.put_prop((void*)(HString*)heap.strs[heap::BuiltinStr.LENGTH], len_tv, hobject::PROP_FLAGS_NWC);
    HString* name_str = builtin_intern_string(heap, "Proxy");
    TVal name_tv; name_tv.set_string(name_str);
    ctor.put_prop(builtin_intern_string(heap, "name"), name_tv, hobject::PROP_FLAGS_NWC);

    HString* revocable_key = builtin_intern_string(heap, "revocable");
    TVal rev_tv;
    rev_tv.set_lightfunc((void*)(usz)Builtin.PROXY_REVOCABLE.ordinal);
    ctor.put_prop(revocable_key, rev_tv, hobject::PROP_FLAGS_WC);

    TVal ctor_tv; ctor_tv.set_object(ctor);
    return register_named_value(global_env, heap, "Proxy", ctor_tv);
}
