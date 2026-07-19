/// GeneratorFunction and Generator.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::bytecode;
import duktape::hstring;
import duktape::env;

import duktape::heap;
import duktape::hobject;
import duktape::compiler;
import duktape::lexer;
import libc;

// ============================================================================
// GeneratorFunction constructor (ES6 §25.2.1)
// ============================================================================

/// Build a dynamic generator/async function from param + body strings, per
/// ES2019 §19.2.1.1.1 CreateDynamicFunction.  is_generator / is_async select
/// which keyword prefix appears in the retained source text and which compile
/// flags are set on the CompilerContext.
fn void builtin_dynamic_gen_function(BuiltinContext* ctx, bool is_gen, bool is_async) {
    char* body_str = "";
    usz body_len = 0;
    char[256] param_buf;
    int param_pos = 0;

    if (ctx.argc > 0) {
        TVal* body_arg = &ctx.regs[ctx.base_reg + (uint)(ctx.argc - 1)];
        if (body_arg.is_string() && body_arg.get_heapptr() != null) {
            HString* s = (HString*)body_arg.get_heapptr();
            body_str = s.get_cstr();
            body_len = s.blen;
        }
        for (ushort i = 0; i < ctx.argc - 1; i++) {
            TVal* arg = &ctx.regs[ctx.base_reg + (uint)i];
            char* pname = "";
            usz plen = 0;
            if (arg.is_string() && arg.get_heapptr() != null) {
                HString* s = (HString*)arg.get_heapptr();
                pname = s.get_cstr();
                plen = s.blen;
            }
            if (param_pos > 0 && param_pos < 255) param_buf[param_pos++] = ',';
            for (usz j = 0; j < plen && param_pos < 255; j++) param_buf[param_pos++] = pname[j];
        }
    }
    param_buf[param_pos] = 0;

    // Compilation source: (params\n) {\n body \n}
    char[16384] src_buf;
    int src_pos = 0;
    src_pos += libc::snprintf(&src_buf[src_pos], (usz)(16384 - src_pos), "(%s\n){\n", param_buf);
    for (usz i = 0; i < body_len && src_pos < 16377; i++) src_buf[src_pos++] = body_str[i];
    src_pos += libc::snprintf(&src_buf[src_pos], (usz)(16384 - src_pos), "\n}");

    lexer::Lexer lex = lexer::lexer_init(src_buf[:src_pos], ctx.heap);
    CompiledFunction*? cf = compiler::compile_function_kind(&lex, ctx.heap, true, is_gen, is_async);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        builtin_throw_no_result_change(ctx, ctx.heap.syntax_err_proto, "SyntaxError in GeneratorFunction constructor");
        return;
    }

    // Build spec-formatted source text: "function* anonymous(\nparams\n) {\nbody\n}"
    {
        char[16384] spec_buf;
        int spec_pos = 0;
        char[] kw = is_async ? (is_gen ? "async function* " : "async function ") : (is_gen ? "function* " : "function ");
        spec_pos += libc::snprintf(&spec_buf[spec_pos], (usz)(16384 - spec_pos), "%.*sanonymous(%s\n) {\n", (int)kw.len, kw.ptr, param_buf);
        for (usz i = 0; i < body_len && spec_pos < 16378; i++) spec_buf[spec_pos++] = body_str[i];
        spec_pos += libc::snprintf(&spec_buf[spec_pos], (usz)(16384 - spec_pos), "\n}");
        if (spec_pos > 0) {
            char* spec_heap = (char*)alloc::malloc_try(mem, (sz)((usz)spec_pos)) ?? null;
            if (spec_heap != null) {
                for (int i = 0; i < spec_pos; i++) spec_heap[i] = spec_buf[i];
                if (func.src_ptr != null) mem::free(func.src_ptr);
                func.src_ptr = spec_heap;
                func.src_len = (uint)spec_pos;
            }
        }
    }

    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) { ctx.result.set_undefined(); return; }
    HObject* func_obj = func_obj_raw;
    (*func_obj.extra_ptr()).func.comp_func = func;
    (*func_obj.extra_ptr()).func.builtin_fn_index = -1;
    (*func_obj.extra_ptr()).func.var_env = ctx.global_env;
    (*func_obj.extra_ptr()).func.lex_env = ctx.global_env;

    // Set [[Prototype]] of the returned function object (ES2015 §9.2.2
    // [[Construct]] step 5/2.a: OrdinaryCreateFromConstructor(newTarget, ...)
    // so `class Sub extends GeneratorFunction {}` produces an instance whose
    // [[Prototype]] is Sub.prototype, not %GeneratorFunction.prototype%):
    // async functions → AsyncFunction.prototype, generator functions → GeneratorFunction.prototype
    HObject* default_fn_proto;
    if (is_async && ctx.heap.async_func_proto != null) {
        default_fn_proto = ctx.heap.async_func_proto;
    } else if (ctx.heap.generator_func_proto != null) {
        default_fn_proto = ctx.heap.generator_func_proto;
    } else {
        default_fn_proto = ctx.heap.function_proto;
    }
    func_obj.prototype = builtin_proto_from_new_target(ctx, default_fn_proto);

    // Prototype object for generator instances (25.2.4.3: writable,
    // non-enumerable, non-configurable — matches Function instances).
    HObject*? gen_proto_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try gen_proto = gen_proto_raw) {
        gen_proto.prototype = ctx.heap.generator_proto;
        HString* proto_key = builtin_intern_string(ctx.heap, "prototype");
        TVal proto_tv;
        proto_tv.set_object(gen_proto);
        func_obj.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_WENC);
    }

    // .length (25.2.4.1) and .name (25.2.4.2): non-writable, non-enumerable,
    // configurable — same as CreateDynamicFunction for plain Function.
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_tv;
    len_tv.set_fastint((long)func.num_formals);
    func_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);

    HString* name_key = builtin_intern_string(ctx.heap, "name");
    TVal name_tv;
    name_tv.set_string(builtin_intern_string(ctx.heap, "anonymous"));
    func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);

    // GeneratorFunction/AsyncFunction instances are callable but not
    // constructable (ES2015 §25.2.3 / §25.7.3 — `new gfn()` throws TypeError).
    func_obj.flags.callable = true;
    func_obj.flags.constructable = false;

    ctx.result.set_object(func_obj);
}

fn void builtin_generator_function(BuiltinContext* ctx) {
    builtin_dynamic_gen_function(ctx, true, false);
}

fn void builtin_async_function(BuiltinContext* ctx) {
    builtin_dynamic_gen_function(ctx, false, true);
}

// ============================================================================
// Generator.prototype.next(value) — ES6 §25.3.1.2
// ============================================================================

fn void builtin_generator_proto_next(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.set_undefined();
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)(*gen_obj.extra_ptr()).gen.generator_data;
    if (gs == null) {
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        // ES6 §25.3.1.2: throw TypeError if .next() called while executing
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Generator is executing");
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        } else {
            ctx.result.set_undefined();
        }
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal undef_val;
            undef_val.set_undefined();
            r.put_prop(value_key, undef_val, hobject::PROP_FLAGS_WEC);

            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.set_boolean(true);
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(r);
        }
        return;
    }

    // Set the resume value
    if (ctx.argc >= 1) {
        gs.resume_value = ctx.regs[ctx.base_reg];
    } else {
        gs.resume_value.set_undefined();
    }

    // Set heap.resume_gen so the CALL handler knows to resume
    gs.resume_kind = NEXT;
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*func_obj.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*func_obj.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Replace callee slot (base_reg - 2) with the generator body wrapper.
    // Do NOT touch base_reg - 1: the caller may store the generator object
    // there as the 'this' value for the next .next() call (e.g. for-of loops).
    // The resume path reads this_binding from gs.this_binding directly.
    ctx.regs[ctx.base_reg - 2] = func_tv;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator.prototype.throw(exception) — ES6 §25.3.1.4
// ============================================================================

fn void builtin_generator_proto_throw(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.set_undefined();
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)(*gen_obj.extra_ptr()).gen.generator_data;
    if (gs == null) {
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        // Already completed — propagate the exception (ES6 §25.3.1.4.a)
        ctx.should_throw = true;
        if (ctx.argc >= 1) {
            ctx.throw_value = ctx.regs[ctx.base_reg];
        } else {
            ctx.throw_value.set_undefined();
        }
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        // ES6 §25.3.1.4: throw TypeError if .throw() called while executing
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Generator is executing");
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        } else {
            ctx.result.set_undefined();
        }
        return;
    }

    // Set the exception to inject
    if (ctx.argc >= 1) {
        gs.throw_value = ctx.regs[ctx.base_reg];
    } else {
        gs.throw_value.set_undefined();
    }
    gs.resume_kind = THROW;

    // Set heap.resume_gen so the CALL handler knows to resume
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        gs.resume_kind = NEXT;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*func_obj.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*func_obj.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Replace callee slot with the generator body wrapper.
    // Do NOT touch base_reg - 1: the caller may store the generator object
    // there as the 'this' value for the next .next() call.
    ctx.regs[ctx.base_reg - 2] = func_tv;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator.prototype.return(value) — ES6 §25.3.1.3
// ============================================================================

fn void builtin_generator_proto_return(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.set_undefined();
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)(*gen_obj.extra_ptr()).gen.generator_data;
    if (gs == null) {
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        // Already completed — return {value: argument, done: true}
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal arg_val;
            if (ctx.argc >= 1) {
                arg_val = ctx.regs[ctx.base_reg];
            } else {
                arg_val.set_undefined();
            }
            r.put_prop(value_key, arg_val, hobject::PROP_FLAGS_WEC);

            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.set_boolean(true);
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(r);
        }
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        // ES6 §25.3.1.3: throw TypeError if .return() called while executing
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Generator is executing");
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        } else {
            ctx.result.set_undefined();
        }
        return;
    }

    if (gs.state == GEN_SUSPENDED_START) {
        // Generator has never executed — complete immediately without
        // executing any body code (ES6 §25.3.1.3, step 5).
        gs.state = GEN_COMPLETED;
        TVal arg_val;
        if (ctx.argc >= 1) {
            arg_val = ctx.regs[ctx.base_reg];
        } else {
            arg_val.set_undefined();
        }
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            r.put_prop(value_key, arg_val, hobject::PROP_FLAGS_WEC);
            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.set_boolean(true);
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
            ctx.result.set_object(r);
        }
        return;
    }

    // Set the return value to inject
    if (ctx.argc >= 1) {
        gs.return_value = ctx.regs[ctx.base_reg];
    } else {
        gs.return_value.set_undefined();
    }
    gs.resume_kind = RETURN;

    // Set heap.resume_gen so the CALL handler knows to resume
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        gs.resume_kind = NEXT;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*func_obj.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*func_obj.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Replace callee slot with the generator body wrapper.
    // Do NOT touch base_reg - 1: the caller may store the generator object
    // there as the 'this' value for the next .next() call.
    ctx.regs[ctx.base_reg - 2] = func_tv;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator constructor registration
// ============================================================================

fn bool register_generator_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Generator.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.generator_proto = proto;

    // Register prototype methods
    if (!register_string_proto_method(proto, heap, "next",   Builtin.GENERATOR_PROTO_NEXT.ordinal))   return false;
    if (!register_string_proto_method(proto, heap, "throw",  Builtin.GENERATOR_PROTO_THROW.ordinal))  return false;
    if (!register_string_proto_method(proto, heap, "return", Builtin.GENERATOR_PROTO_RETURN.ordinal)) return false;

    // Add [Symbol.iterator]() → returns `this` (ES6 §25.3.1.12)
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.ITERATOR_PROTO_SYMBOL_ITER.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal iter_tv;
            iter_tv.set_object(fn_obj);
            proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_WC);
        }
    }

    // Set @@toStringTag on Generator.prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Generator"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Create GeneratorFunction.prototype (ES6 §25.2.3)
    // This is the prototype of all generator function objects.
    // It inherits from Function.prototype.
    HObject*? gf_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = gf_proto_raw) return false;
    HObject* gf_proto = gf_proto_raw;
    gf_proto.prototype = heap.function_proto;
    heap.generator_func_proto = gf_proto;

    // Set GeneratorFunction.prototype.prototype → Generator.prototype
    // (ES2015 §25.2.3.3): the shared prototype every individual generator
    // function's own `.prototype` object inherits from — this is what
    // `Object.getPrototypeOf(function* () {}).prototype` reads.
    // {writable:false, enumerable:false, configurable:true}.
    {
        HString* gf_prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal gf_prototype_tv;
        gf_prototype_tv.set_object(proto);
        gf_proto.put_prop(gf_prototype_key, gf_prototype_tv, hobject::PROP_FLAGS_NWC);
    }

    // Set GeneratorFunction.prototype.constructor → GeneratorFunction
    // (will be filled in after creating the ctor object below)

    // Set @@toStringTag on GeneratorFunction.prototype
    {
        HString* gf_tag_key = ensure_tostringtag_symbol(heap);
        if (gf_tag_key != null) {
            TVal tag_tv;
            tag_tv.set_string(builtin_intern_string(heap, "GeneratorFunction"));
            gf_proto.put_prop(gf_tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    // Create GeneratorFunction constructor HObject (ES6 §25.2.2)
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.GENERATOR_FUNCTION.ordinal;
    ctor.flags.callable = true;
    ctor.prototype = heap.function_proto;

    // Wire Generator.prototype.constructor → GeneratorFunction
    {
        HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
        TVal constructor_tv;
        constructor_tv.set_object(ctor);
        proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    }

    // Wire GeneratorFunction.prototype.constructor → GeneratorFunction
    {
        HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
        TVal constructor_tv;
        constructor_tv.set_object(ctor);
        gf_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    }

    // Wire GeneratorFunction.prototype → GeneratorFunction.prototype object
    // (non-writable, non-enumerable, non-configurable per ES6 §19.2.4.3)
    {
        HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal gf_proto_tv;
        gf_proto_tv.set_object(gf_proto);
        PropFlags proto_pflags;
        proto_pflags.writable = false;
        proto_pflags.enumerable = false;
        proto_pflags.configurable = false;
        proto_pflags.is_accessor = false;
        ctor.put_prop(prototype_key, gf_proto_tv, proto_pflags);
    }

    // GeneratorFunction.length = 1 (ES6 §25.2.2)
    {
        HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        TVal length_tv;
        length_tv.set_fastint(1);
        ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);
    }

    // GeneratorFunction.name = "GeneratorFunction" (ES6 §25.2.2)
    set_func_ctor_name(ctor, heap, "GeneratorFunction");

    // Register GeneratorFunction as a global constructor
    {
        uint hash = heap.hash_string("GeneratorFunction");
        HString* existing = heap.str_table_lookup("GeneratorFunction", hash);
        HString* gf_key;
        if (existing != null) {
            gf_key = existing;
        } else {
            HString*? new_key = hstring::hstring_alloc(heap, "GeneratorFunction", hash);
            if (catch err = new_key) return false;
            heap.str_table_insert(new_key);
            gf_key = new_key;
        }
        TVal gf_tv;
        gf_tv.set_object(ctor);
        env::env_declare_nonenum(global_env, gf_key, gf_tv);
    }

    // ── AsyncFunction infrastructure (ES2017 §25.7) ──────────────────────────
    // AsyncFunction.prototype inherits from Function.prototype (§25.7.3).
    HObject*? af_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = af_proto_raw) return false;
    HObject* af_proto = af_proto_raw;
    af_proto.prototype = heap.function_proto;
    heap.async_func_proto = af_proto;

    // @@toStringTag on AsyncFunction.prototype = "AsyncFunction"
    {
        HString* af_tag_key = ensure_tostringtag_symbol(heap);
        if (af_tag_key != null) {
            TVal tag_tv;
            tag_tv.set_string(builtin_intern_string(heap, "AsyncFunction"));
            af_proto.put_prop(af_tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    // AsyncFunction constructor object
    HObject*? af_ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = af_ctor_raw) return false;
    HObject* af_ctor = af_ctor_raw;
    (*af_ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_FUNCTION.ordinal;
    af_ctor.flags.callable = true;
    af_ctor.prototype = heap.function_proto;

    // AsyncFunction.prototype.constructor → AsyncFunction
    {
        HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
        TVal constructor_tv;
        constructor_tv.set_object(af_ctor);
        af_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    }

    // AsyncFunction.prototype → af_proto (non-writable, non-enumerable, non-configurable)
    {
        HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal af_proto_tv;
        af_proto_tv.set_object(af_proto);
        PropFlags proto_pflags;
        proto_pflags.writable = false;
        proto_pflags.enumerable = false;
        proto_pflags.configurable = false;
        proto_pflags.is_accessor = false;
        af_ctor.put_prop(prototype_key, af_proto_tv, proto_pflags);
    }

    // AsyncFunction.length = 1, AsyncFunction.name = "AsyncFunction"
    {
        HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        TVal length_tv;
        length_tv.set_fastint(1);
        af_ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);
    }
    set_func_ctor_name(af_ctor, heap, "AsyncFunction");

    return true;
}
