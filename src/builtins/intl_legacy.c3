// ECMA-402 legacy constructor chaining and UnwrapNumber/DateTimeFormat.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;

fn HString* intl_fallback_symbol(Heap* hp) => ensure_cached_symbol(hp, &hp.intl_fallback_symbol, "IntlLegacyConstructedSymbol");

// OrdinaryHasInstance uses the intrinsic constructor's fixed prototype and
// routes proxy hops through [[GetPrototypeOf]], without consulting @@hasInstance.
fn bool intl_legacy_instance(BuiltinContext* ctx, TVal value, long class_id) {
    if (!value.is_object()) return false;
    HObject* target = ctx.heap.host_class_at((uint)class_id).proto;
    HObject* obj = (HObject*)value.get_heapptr();
    for (uint depth = 0; obj != null && depth < 256; depth++) {
        if (obj.flags.exotic_proxyobj) {
            TVal next;
            if (!proxy_mop_get_proto(ctx.vm, ctx.heap, obj, &next)) { proxy_ctx_ok(ctx); return false; }
            obj = next.is_object() ? (HObject*)next.get_heapptr() : null;
        } else { obj = obj.prototype; }
        if (obj == target) return true;
    }
    return false;
}
fn bool intl_initialized(Heap* hp, TVal value, long class_id) {
    if (!value.is_object()) return false;
    HObject* obj = (HObject*)value.get_heapptr();
    HostClassEntry* entry = hp.host_class_at((uint)class_id);
    HString* name = entry != null ? entry.name.borrow() : null;
    return name != null && intl_has_brand(hp, obj, name.get_data());
}
fn HObject* intl_legacy_unwrap(BuiltinContext* ctx, long class_id, bool legacy) {
    TVal value = ctx.regs[ctx.base_reg - 1];
    if (intl_initialized(ctx.heap, value, class_id)) return (HObject*)value.get_heapptr();
    if (legacy && intl_legacy_instance(ctx, value, class_id)) {
        HString* symbol = intl_fallback_symbol(ctx.heap);
        if (symbol == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return null; }
        TVal? stored = builtins_generic_get((HObject*)value.get_heapptr(), symbol, ctx);
        if (ctx.should_throw) return null;
        if (try v = stored) {
            if (intl_initialized(ctx.heap, v, class_id)) return (HObject*)v.get_heapptr();
        }
    }
    if (!ctx.should_throw) builtin_throw(ctx, ctx.heap.type_err_proto, "incompatible Intl receiver");
    return null;
}
fn void intl_legacy_chain(BuiltinContext* ctx, HObject* formatter, long class_id) {
    TVal receiver = ctx.regs[ctx.base_reg - 1];
    if (!ctx.is_constructor && intl_legacy_instance(ctx, receiver, class_id)) {
        HString* symbol = intl_fallback_symbol(ctx.heap);
        if (symbol == null) { builtin_throw(ctx, ctx.heap.err_proto, "Intl allocation failed"); return; }
        ProxyDesc desc;
        desc.has_value = true; desc.value.set_object(formatter);
        desc.has_writable = true; desc.has_enumerable = true; desc.has_configurable = true;
        bool defined;
        HObject* obj = (HObject*)receiver.get_heapptr();
        if (!object_define_own(ctx.vm, ctx.heap, obj, symbol, &desc, &defined)) { proxy_ctx_ok(ctx); return; }
        if (!defined) { builtin_throw(ctx, ctx.heap.type_err_proto, "cannot define Intl legacy formatter"); return; }
        ctx.result_object(obj);
        return;
    }
    if (!ctx.should_throw) ctx.result_object(formatter);
}
