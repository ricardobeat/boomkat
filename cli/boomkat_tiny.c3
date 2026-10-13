// Host generator and device runner share a strict Module-goal bytecode format.
module boomkat;

import boomkat::image;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::vm;
import boomkat::types;
import boomkat::env;
import boomkat::builtins;
import boomkat::bytecode;
import std::io;
import std::collections::list;

fn void bytecode_rejection(void* heap_raw, void* vm_raw, TVal promise, TVal reason, void* udata) {
    *(bool*)udata = true;
    io::eprintf("Unhandled promise rejection: ");
    print_tval_stderr((Heap*)heap_raw, &reason);
    io::eprintfn("");
}

fn int main(String[] args) {
    if (args.len != 2) {
        io::eprintfn("Usage: boomkat_tiny INPUT.bkbc"); return 2;
    }
    char[]? input = file::load(mem, args[1]);
    if (catch err = input) { io::eprintfn("Could not read %s", args[1]); return 1; }
    char[] source = input;
    defer mem::free(source);
    Heap* hp = heap::create(null, null, null, null, null) ?? null;
    if (hp == null) return 1;
    defer hp.destroy();
    // Initialization supplies the same builtin ordinals and prototypes as
    // the generator's source-running preset, without compiling source.
    Vm* v = vm::vm_create(hp) ?? null;
    if (v == null) return 1;
    defer vm::vm_destroy(v);
    bool rejection = false;
    hp.set_rejection_tracker(&bytecode_rejection, &rejection);
    List{image::ModuleDecl} declarations;
    declarations.init(mem);
    defer declarations.free();
    CompiledFunction*? loaded = image::decode(hp, source, &declarations);
    if (catch err = loaded) { io::eprintfn("Invalid or incompatible bytecode: %s", err); return 1; }
    EnvRecord* module_env = env::env_create_declarative(hp, v.global_env) ?? null;
    if (module_env == null) return 1;
    module_env.flags.is_module = true;
    hp.register_gc_root(module_env.bindings.as_header());
    foreach (decl : declarations) {
        HString* name = hp.str_intern(decl.name);
        HObject* closure = vm::instantiate_closure(v, decl.template, module_env, module_env);
        if (name == null || closure == null) return 1;
        TVal value; value.set_object(closure);
        env::env_declare(module_env, name, value);
    }
    // Module-local vars and functions stay out of the global object.
    HObject* pending = null;
    CompiledFunction* f = loaded;
    if (f.has_tla()) {
        bool? ok = v.execute_module_async(f, module_env, &pending);
        if (catch err = ok) { io::eprintfn("VM error: %s", err); return 1; }
        hp.drain_microtasks(v);
        if (pending != null) {
            uint state = builtins::promise_get_state(pending, builtins::PROMISE_PENDING);
            if (state == builtins::PROMISE_PENDING) {
                io::eprintfn("Module evaluation is still pending"); return 1;
            }
            if (state == builtins::PROMISE_REJECTED) {
                TVal reason = builtins::promise_get_result(pending);
                print_uncaught(hp, &reason); return 1;
            }
            hp.decref(pending.as_header());
        }
        if (!ok) { print_uncaught(hp, &hp.error_value); return 1; }
        return rejection ? 1 : 0;
    }
    TVal? result = v.execute_in_env(f, module_env);
    if (catch err = result) {
        if (hp.has_error) { print_uncaught(hp, &hp.error_value); }
        else { io::eprintfn("VM error: %s", err); }
        return 1;
    }
    hp.drain_microtasks(v);
    return rejection ? 1 : 0;
}

fn void print_uncaught(Heap* hp, TVal* err_val) {
    // Error objects report as `Uncaught <name>: <message>`, the shape every
    // JS shell prints and that test262 harnesses parse to recover the error
    // type of a `negative:` test.
    if (err_val.is_object()) {
        HObject* obj = (HObject*)err_val.get_heapptr();
        if (obj != null) {
            HString* msg_str = error_message_of(hp, obj);
            HString* name_str = msg_str != null ? error_name_of(hp, obj) : null;
            if (name_str != null) {
                io::eprintf("Uncaught ");
                print_hstring_stderr(name_str);
                io::eprintf(": ");
                print_hstring_stderr(msg_str);
                io::eprintf("\n");
                return;
            }
        }
    }
    io::eprintf("Uncaught: ");
    print_tval_stderr(hp, err_val);
    io::eprintf("\n");
}

// The `message` of a thrown object, own or inherited, when it is a string.
// A thrown array or plain object has none: that absence is what distinguishes
// an error-shaped value from any other object, and reporting
// `Uncaught Array: [object]` for one would be noise, not information.
fn HString* error_message_of(Heap* hp, HObject* obj) {
    HString* msg_key = (HString*)hp.strs[heap::BuiltinStr.MESSAGE];
    TVal? msg_opt = obj.get_prop_proto(msg_key, hp);
    if (try msg_tv = msg_opt) {
        if (msg_tv.is_string()) return (HString*)msg_tv.get_heapptr();
    }
    return null;
}

// The error type name of a thrown object: its `name` property, or failing that
// its `constructor.name` (which is what names host error types such as
// Test262Error). Returns null when neither yields a string.
fn HString* error_name_of(Heap* hp, HObject* obj) {
    HString* name_key = (HString*)hp.strs[heap::BuiltinStr.NAME];
    TVal? name_opt = obj.get_prop_proto(name_key, hp);
    if (try name_tv = name_opt) {
        if (name_tv.is_string()) return (HString*)name_tv.get_heapptr();
    }
    HString* ctor_key = (HString*)hp.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal? ctor_opt = obj.get_prop_proto(ctor_key, hp);
    if (try ctor_tv = ctor_opt) {
        if (ctor_tv.is_object()) {
            HObject* ctor = (HObject*)ctor_tv.get_heapptr();
            if (ctor != null) {
                TVal? cname_opt = ctor.get_prop_proto(name_key, hp);
                if (try cname_tv = cname_opt) {
                    if (cname_tv.is_string()) return (HString*)cname_tv.get_heapptr();
                }
            }
        }
    }
    return null;
}

// Format a single TVal for stderr. Objects print their string `message` property
// when present, or a fallback tag.
fn void print_tval_stderr(Heap* hp, TVal* v) {
    switch (v.get_tag()) {
        case types::TValTag.UNDEFINED: io::eprintf("undefined"); return;
        case types::TValTag.NULL_VAL:  io::eprintf("null");      return;
        case types::TValTag.BOOLEAN:   io::eprintf(v.get_boolean() ? "true" : "false"); return;
        case types::TValTag.FASTINT:   io::eprintf("%d", v.get_fastint()); return;
        case types::TValTag.NUMBER:    io::eprintf("%g", v.get_number()); return;
        case types::TValTag.STRING:    print_hstring_stderr((HString*)v.get_heapptr()); return;
        default: break;
    }
    if (!v.is_object()) {
        io::eprintf("<unknown value>");
        return;
    }
    HObject* obj = (HObject*)v.get_heapptr();
    if (obj == null) {
        io::eprintf("<null object>");
        return;
    }
    // Print the message property for error objects.
    HString* msg_key = (HString*)hp.strs[heap::BuiltinStr.MESSAGE];
    TVal? msg_tv_opt = obj.get_prop(msg_key, hp);
    if (try msg_tv = msg_tv_opt) {
        if (msg_tv.is_string()) {
            print_hstring_stderr((HString*)msg_tv.get_heapptr());
            return;
        }
    }
    io::eprintf("[object]");
}

fn void print_hstring_stderr(HString* s) {
    if (s == null) {
        io::eprintf("<null string>");
        return;
    }
    char[] d = s.get_data();
    for (usz i = 0; i < d.len; i++) io::eprintf("%c", d[i]);
}
