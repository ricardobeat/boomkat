/// ESM module system — data structures, host API, loader, linker.
///
/// Implements the ES6 module lifecycle:
///   1. COMPILE:  compile_module() → parse import/export → emit bytecode → ModuleDef
///   2. RESOLVE:  load all transitive dependencies (recursive compile_module)
///   3. LINK:     share env bindings between modules for live exports
///   4. EXECUTE:  run module body (top-level statements)
///   5. NAMESPACE: build Module Namespace Object for `import *`
module duktape::esm;

import duktape::types;
import duktape::bytecode;
import duktape::env;
import duktape::heap;
import duktape::hobject;
import duktape::hstring;
import duktape::lexer;
import duktape::compiler;
import duktape::builtins;
import duktape::vm;
import std::io;

// ============================================================================
// Fault codes
// ============================================================================

faultdef MODULE_ERROR;

// ============================================================================
// Module status lifecycle
// ============================================================================

enum ModuleStatus : char {
    UNLOADED,
    LOADING,       // currently being compiled (cycle detection)
    LOADED,        // compiled, not yet linked
    LINKING,       // being linked
    LINKED,        // ready for evaluation
    EVALUATING,    // being executed
    EVALUATED,     // fully executed
}

// ============================================================================
// Import/export metadata entries
// ============================================================================

struct ImportEntry {
    char[] local_name;      // the local binding name ("foo", "default", "ns")
    char[] import_name;     // the imported name ("foo", "default", "*")
    uint   req_module_idx;  // index into ModuleDef.req_modules
    bool   is_star;         // true for `import * as ns`
    bool   is_default;      // true for `import foo from ...`
}

struct ExportEntry {
    char[] local_name;      // the local binding name
    char[] export_name;     // the exported name ("default" for default export)
    bool   is_indirect;     // true for `export { x } from './other'`
    uint   req_module_idx;  // for indirect exports
    // True when the local binding is `let`/`const`/`class` (a lexical
    // declaration subject to TDZ). False for `var`/`function` exports,
    // which are hoisted/initialized and never observed as TDZ even when
    // read before the exporting module's body has run. Unused (false) for
    // indirect exports, whose TDZ-ness is determined by the source module.
    // Function-declaration exports are tracked separately (ModuleDef.func_decls)
    // and instantiated at link time, so they don't need a flag here.
    bool   is_lexical;
}

struct StarExportEntry {
    uint req_module_idx;    // index into ModuleDef.req_modules
}

struct ReqModuleEntry {
    char[]       module_name;   // the specifier string
    void*        resolved;      // ModuleDef* filled during resolve phase (opaque to avoid cycle)
}

// ============================================================================
// ModuleHostHooks — pluggable host callbacks
// ============================================================================

alias ResolveNameFn = fn char[]?(char[] base_name, char[] specifier, void* udata);
alias ReadSourceFn  = fn char[]?(char[] normalized_name, void* udata);
alias OnModuleLoadedFn    = fn void?(void* mod, void* udata);
alias OnModuleEvaluatedFn = fn void?(void* mod, void* udata);

struct ModuleHostHooks {
    ResolveNameFn      resolve_name;
    ReadSourceFn       read_source;
    OnModuleLoadedFn   on_module_loaded;
    OnModuleEvaluatedFn on_module_evaluated;
    void*              udata;
}

// ============================================================================
// ModuleDef — a single module's definition
// ============================================================================

const uint MAX_IMPORTS      = 64;
const uint MAX_EXPORTS      = 64;
const uint MAX_STAR_EXPORTS = 16;
const uint MAX_REQ_MODULES  = 32;
const uint MAX_FUNC_DECLS   = 128;

/// A top-level `function` declaration in a module body. Recorded by the
/// compiler during hoist_global_fn_decls so the linker can instantiate the
/// closure once, during InitializeEnvironment (ECMA-262 16.2.1.5.5 step 17),
/// rather than the body re-instantiating it on every evaluation.
struct FuncDeclEntry {
    char[] name;            // the declared function's binding name
    uint   inner_func_idx;  // index into mod.func.inner_funcs
}

struct ModuleDef {
    char[]                module_name;    // normalized path / identifier
    ModuleStatus          status;

    // Import/export metadata (populated during compilation)
    ImportEntry[MAX_IMPORTS]      imports;
    uint                          import_count;
    ExportEntry[MAX_EXPORTS]      exports;
    uint                          export_count;
    StarExportEntry[MAX_STAR_EXPORTS] star_exports;
    uint                          star_export_count;
    ReqModuleEntry[MAX_REQ_MODULES] req_modules;
    uint                          req_module_count;
    // Top-level function declarations, instantiated eagerly at link time.
    // Layout note: CompModuleDef mirrors every field up to here, so this
    // array must appear in both structs at the same position.
    FuncDeclEntry[MAX_FUNC_DECLS] func_decls;
    uint                          func_decl_count;

    // Compiled bytecode for this module's body
    bytecode::CompiledFunction*   func;

    // Runtime environment holding this module's bindings
    env::EnvRecord*               env;

    // Module namespace object (lazily created for `import *`)
    HObject*                      namespace_obj;
}

// ============================================================================
// Module cache on Heap
// ============================================================================

const uint INITIAL_MODULE_CAP = 16;

/// Find a loaded module by normalized name. Returns null if not found.
fn ModuleDef* heap_find_loaded_module(Heap* heap, char[] name) {
    if (heap.module_cache == null) return null;
    ModuleDef** cache = (ModuleDef**)heap.module_cache;
    for (uint i = 0; i < heap.module_cache_count; i++) {
        if (cache[i] != null && cache[i].module_name.len == name.len) {
            bool match = true;
            for (usz j = 0; j < name.len; j++) {
                if (cache[i].module_name[j] != name[j]) { match = false; break; }
            }
            if (match) return cache[i];
        }
    }
    return null;
}

// ============================================================================
// Default module host callbacks
// ============================================================================

/// Default source reader: read a module file from disk into a caller-owned
/// buffer allocated from the engine's `mem` (libc-backed) heap. The returned
/// slice is exactly the file's bytes; the lexer scans by length (no NUL
/// sentinel required).
fn char[]? default_module_read(char[] normalized_name, void* udata) {
    char[] data = file::load(mem, (String)normalized_name) ?? MODULE_ERROR~!;
    if (data.len == 0) {
        mem::free(data.ptr);
        return MODULE_ERROR~;
    }
    return data;
}

// ============================================================================
// Module loader — resolve, load, compile, link, execute
// ============================================================================

/// Call the host's resolve_name hook, or use the default.
fn char[]? call_resolve_name(Heap* heap, char[] base_name, char[] specifier) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.resolve_name != null) {
            return hooks.resolve_name(base_name, specifier, hooks.udata);
        }
    }
    // Bare specifier (no leading dot) — return as-is
    if (specifier.len > 0 && specifier[0] != '.') return specifier;
    // Relative specifier — resolve against base_name's directory
    if (base_name.len == 0) return specifier;
    // Find last '/' in base_name to get directory
    int last_slash = -1;
    for (usz i = 0; i < base_name.len; i++) {
        if (base_name[i] == '/') last_slash = (int)i;
    }
    if (last_slash < 0) return specifier;
    char[] dir = base_name[:last_slash + 1];
    char[] rel = specifier;
    if (rel.len >= 2 && rel[0] == '.' && rel[1] == '/') {
        rel = rel[2..];
    }
    usz total = dir.len + rel.len;
    void* raw = alloc::malloc_try(mem, (sz)(total + 1)) ?? null;
    if (raw == null) return MODULE_ERROR~;
    mem::copy(raw, dir.ptr, (sz)(dir.len));
    mem::copy((char*)raw + dir.len, rel.ptr, (sz)(rel.len));
    ((char*)raw)[total] = 0;
    char[] result = ((char*)raw)[:total];
    return result;
}

/// Call the host's read_source hook, or use the default.
fn char[]? call_read_source(Heap* heap, char[] normalized_name) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.read_source != null) {
            return hooks.read_source(normalized_name, hooks.udata);
        }
    }
    return default_module_read(normalized_name, null);
}

/// Call the host's on_module_loaded hook (if set).
fn void call_on_module_loaded(Heap* heap, void* mod) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.on_module_loaded != null) {
            (void)hooks.on_module_loaded(mod, hooks.udata);
        }
    }
}

/// Call the host's on_module_evaluated hook (if set).
fn void call_on_module_evaluated(Heap* heap, void* mod) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.on_module_evaluated != null) {
            (void)hooks.on_module_evaluated(mod, hooks.udata);
        }
    }
}

/// Find or create a ModuleDef by name in the heap's module cache.
fn ModuleDef*? heap_ensure_module(Heap* heap, char[] name) {
    // Check existing cache
    if (heap.module_cache != null) {
        ModuleDef** cache = (ModuleDef**)heap.module_cache;
        for (uint i = 0; i < heap.module_cache_count; i++) {
            if (cache[i] != null && cache[i].module_name.len == name.len) {
                bool match = true;
                for (usz j = 0; j < name.len; j++) {
                    if (cache[i].module_name[j] != name[j]) { match = false; break; }
                }
                if (match) return cache[i];
            }
        }
    }

    // Allocate new ModuleDef
    void* raw = heap.alloc_func(heap.heap_udata, ModuleDef::size);
    if (raw == null) return MODULE_ERROR~;
    mem::clear(raw, (sz)(ModuleDef::size));
    ModuleDef* mod = (ModuleDef*)raw;
    mod.module_name = name;
    mod.status = ModuleStatus.UNLOADED;

    // Grow cache if needed
    if (heap.module_cache_count >= heap.module_cache_cap) {
        uint new_cap = heap.module_cache_cap == 0 ? INITIAL_MODULE_CAP : heap.module_cache_cap * 2;
        usz new_bytes = (usz)new_cap * void*::size;
        void* new_arr;
        if (heap.module_cache == null) {
            new_arr = heap.alloc_func(heap.heap_udata, new_bytes);
        } else {
            new_arr = heap.realloc_func(heap.heap_udata, heap.module_cache, new_bytes);
        }
        if (new_arr == null) {
            heap.free_func(heap.heap_udata, raw);
            return MODULE_ERROR~;
        }
        heap.module_cache = new_arr;
        heap.module_cache_cap = new_cap;
    }

    ((ModuleDef**)heap.module_cache)[heap.module_cache_count] = mod;
    heap.module_cache_count++;

    return mod;
}

/// Resolve a module specifier, compile it, and recursively resolve dependencies.
fn ModuleDef*? resolve_module(Heap* heap, char[] specifier, char[] base_name) {
    // 1. Normalize name via host hook
    char[]? normalized_opt = call_resolve_name(heap, base_name, specifier);
    if (catch err = normalized_opt) return MODULE_ERROR~;
    char[] normalized = normalized_opt;

    // 2. Check engine cache
    ModuleDef* cached = heap_find_loaded_module(heap, normalized);
    if (cached != null) return cached;

    // 3. Read source via host hook
    char[]? source_opt = call_read_source(heap, normalized);
    if (catch err = source_opt) return MODULE_ERROR~;
    char[] source = source_opt;
    if (source.len == 0) return MODULE_ERROR~;

    // 4. Create ModuleDef (marks as LOADING for cycle detection)
    ModuleDef*? mod_opt = heap_ensure_module(heap, normalized);
    if (catch err = mod_opt) return MODULE_ERROR~;
    ModuleDef* mod = mod_opt;
    mod.status = ModuleStatus.LOADING;

    // 5. Compile
    Lexer lex = lexer::lexer_init(source, heap);
    lex.skip_hashbang();
    bytecode::CompiledFunction*? func_opt = compiler::compile_module(&lex, heap, normalized, mod);
    if (catch err = func_opt) {
        char* msg  = compiler::last_error_msg();
        uint  line = compiler::last_error_line();
        uint  col  = compiler::last_error_col();
        usz   msg_len = (usz)((ZString)msg).len();
        // Build the module name portion into a temp buffer for printing.
        char[512] name_buf;
        usz name_copy = normalized.len < 511 ? normalized.len : 511;
        mem::copy(&name_buf[0], normalized.ptr, (sz)(name_copy));
        name_buf[name_copy] = 0;
        if (msg_len > 0) {
            io::eprintfn("%s: compile error at line %d:%d: %s",
                         (ZString)name_buf[0..], line, col, (ZString)msg);
        } else {
            io::eprintfn("%s: compile error at line %d:%d",
                         (ZString)name_buf[0..], line, col);
        }
        return MODULE_ERROR~;
    }
    mod.func = func_opt;
    mod.func.filename_ptr = normalized.ptr;
    mod.func.filename_len = (uint)normalized.len;

    // 6. Notify host
    call_on_module_loaded(heap, mod);

    // 7. Recursively resolve dependencies
    for (uint i = 0; i < mod.req_module_count; i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        ModuleDef*? dep = resolve_module(heap, rme.module_name, normalized);
        if (catch err = dep) {
            return MODULE_ERROR~;
        }
        rme.resolved = dep;
    }

    mod.status = ModuleStatus.LOADED;
    return mod;
}

/// Link a module: resolve import bindings from source modules' envs.
/// Phase 1 (initial): import bindings are copied at link time.
fn bool link_module(Heap* heap, vm::Vm* vm, ModuleDef* mod, EnvRecord* global_env) {
    if (mod.status == ModuleStatus.LINKED || mod.status == ModuleStatus.EVALUATED) return true;
    // LINKING means we're already linking this module further up the call
    // stack — a dependency cycle (including a self-import). Treat it as done to
    // break the recursion; its env exists and bindings resolve once the
    // outermost link_module completes. Without this a cyclic import recurses
    // until the C stack overflows (SIGSEGV).
    if (mod.status == ModuleStatus.LINKING) return true;
    // EVALUATING means the module's body is currently running (a dynamic
    // import of a module that is mid-evaluation, e.g. a self-import).
    // Re-linking would replace the live mod.env under the running body and
    // downgrade the status so the body re-executes. It is already linked.
    if (mod.status == ModuleStatus.EVALUATING) return true;
    mod.status = ModuleStatus.LINKING;

    // Create module env (declarative), parented to the global env so that
    // globals (Object, print, Error, ...) resolve via the scope chain from
    // inside module code.
    EnvRecord*? env_opt = env::env_create_declarative(heap, global_env);
    if (catch err = env_opt) return false;
    mod.env = env_opt;
    // Register the env bindings as a GC root so objects stored in the module
    // env (imported bindings, and — below — eagerly instantiated exported
    // function closures) survive collection between link and evaluation.
    // execute_module only roots the env in the path where it creates the env
    // itself; when link_module creates it first (the normal path), that block
    // is skipped, so root it here.
    if (mod.env.bindings != null) {
        heap.register_gc_root(mod.env.bindings.as_header());
    }

    // Link dependencies first
    for (uint i = 0; i < mod.req_module_count; i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        if (rme.resolved == null) continue;
        ModuleDef* dep = (ModuleDef*)rme.resolved;
        if (dep.status != ModuleStatus.LINKED && dep.status != ModuleStatus.EVALUATED) {
            if (!link_module(heap, vm, dep, global_env)) return false;
        }
    }

    // Resolve import bindings: copy values from source module's env
    for (uint i = 0; i < mod.import_count; i++) {
        ImportEntry* ie = &mod.imports[i];
        if (ie.req_module_idx >= mod.req_module_count) continue;
        ReqModuleEntry* rme = &mod.req_modules[ie.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* source_mod = (ModuleDef*)rme.resolved;

        if (ie.is_star) {
            // `import * as ns` — create namespace object
            // For now, skip namespace object creation (Phase 2)
            continue;
        }

        // Look up the exported name in the source module's env
        HString* key = heap.str_intern(ie.import_name);
        if (key == null) continue;

        TVal? val_opt = env::env_get(source_mod.env, key);
        if (catch err = val_opt) {
            // Binding not found — set to undefined (will be live-binding later)
            TVal undef;
            undef.set_undefined();
            env::env_declare(mod.env, key, undef);
        } else {
            env::env_declare(mod.env, key, val_opt);
        }

        // Also declare the local name if different from import name
        if (ie.local_name.len != ie.import_name.len ||
            !char_slice_eq(ie.local_name, ie.import_name)) {
            HString* local_key = heap.str_intern(ie.local_name);
            if (local_key != null) {
                TVal? local_val = env::env_get(source_mod.env, key);
                if (catch err2 = local_val) {
                    TVal undef;
                    undef.set_undefined();
                    env::env_declare(mod.env, local_key, undef);
                } else {
                    env::env_declare(mod.env, local_key, local_val);
                }
            }
        }
    }

    // Resolve indirect exports
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect) continue;
        if (ee.req_module_idx >= mod.req_module_count) continue;
        ReqModuleEntry* rme = &mod.req_modules[ee.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* source_mod = (ModuleDef*)rme.resolved;

        HString* source_key = heap.str_intern(ee.local_name);
        HString* export_key = heap.str_intern(ee.export_name);
        if (source_key == null || export_key == null) continue;

        TVal? val_opt = env::env_get(source_mod.env, source_key);
        if (catch err = val_opt) {
            TVal undef;
            undef.set_undefined();
            env::env_declare(mod.env, export_key, undef);
        } else {
            env::env_declare(mod.env, export_key, val_opt);
        }
    }

    // Instantiate top-level `function` declarations (ECMA-262 16.2.1.5.5
    // step 17). InitializeEnvironment creates each function's closure once,
    // during linking, before ANY module body runs. This is what makes a
    // cyclic early import observe the hoisted function (not undefined) AND
    // keeps the binding's identity stable — the module body no longer emits
    // CLOSURE+DECLVAR for these (see hoist_global_fn_decls). The closure
    // captures the module env as both var and lex environment (its top-level
    // enclosing scope), exactly as the CLOSURE opcode would.
    if (mod.func != null) {
        for (uint i = 0; i < mod.func_decl_count; i++) {
            FuncDeclEntry* fd = &mod.func_decls[i];
            if (fd.inner_func_idx >= mod.func.inner_count) continue;
            HString* key = heap.str_intern(fd.name);
            if (key == null) continue;
            bytecode::CompiledFunction* tmpl = mod.func.get_inner(fd.inner_func_idx);
            HObject* fn_obj = vm::instantiate_closure(vm, tmpl, mod.env, mod.env);
            TVal val;
            if (fn_obj != null) {
                val.set_object(fn_obj);
            } else {
                val.set_undefined();
            }
            // A function declaration wins over any earlier binding of the same
            // name (last-declaration hoisting), so declare unconditionally.
            env::env_declare(mod.env, key, val);
        }
    }

    // Declare remaining local export bindings in the module env, before the
    // module body has run. A `var` export pre-declares as plain `undefined`
    // (the body's DECLVAR sets it later). A `let`/`const`/`class` export is
    // lexical and must pre-declare as the TDZ sentinel (ECMA-262 SS10.4.6.8):
    // the body's own INITTZ (emitted by hoist_lexical_tdz for every
    // module-top-level lexical declaration) only overwrites this slot when the
    // OWNING module's body actually executes, but a live-binding accessor from
    // a cyclically-importing module can observe this env slot beforehand — it
    // must see the sentinel, not undefined, so builtin_module_binding_getter
    // (builtins/core.c3) throws instead of yielding a stale undefined.
    // Function-declaration exports are already bound above and are skipped by
    // the env_has check.
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (ee.is_indirect) continue;
        HString* key = heap.str_intern(ee.local_name);
        if (key == null) continue;
        // Check if already declared (from import resolution or as a function).
        if (!env::env_has(mod.env, key)) {
            TVal val;
            if (ee.is_lexical) {
                val = env::tdz_sentinel();
            } else {
                val.set_undefined();
            }
            env::env_declare(mod.env, key, val);
        }
    }

    mod.status = ModuleStatus.LINKED;
    return true;
}

/// Execute a module: run dependencies first, then resolve imports, then run body.
fn bool execute_module(Heap* heap, Vm* vm, ModuleDef* mod) {
    if (mod.status == ModuleStatus.EVALUATED) return true;
    if (mod.status == ModuleStatus.EVALUATING) return true; // cycle guard
    mod.status = ModuleStatus.EVALUATING;

    // Create module env if not already done, parented to the global env so
    // that globals (console, Error, etc.) are visible inside modules.
    if (mod.env == null) {
        EnvRecord*? env_opt = env::env_create_declarative(heap, vm.global_env);
        if (catch err = env_opt) return false;
        mod.env = env_opt;
        // Register the env bindings as a GC root so that objects stored in module
        // envs (e.g. exported functions) are not swept between module evaluations.
        // (In the normal pipeline link_module creates + roots the env first, so
        // this branch only runs for a module evaluated without a prior link.)
        if (mod.env.bindings != null) {
            heap.register_gc_root(mod.env.bindings.as_header());
        }
    }

    // Execute dependencies first (so their exports are available)
    for (uint i = 0; i < mod.req_module_count; i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        if (rme.resolved == null) continue;
        ModuleDef* dep = (ModuleDef*)rme.resolved;
        if (dep.status != ModuleStatus.EVALUATED) {
            if (!execute_module(heap, vm, dep)) return false;
        }
    }

    // Resolve import bindings against (now-executed) source modules. Both
    // `import * as ns` and named `import { x }` install LIVE accessor
    // bindings (ECMA-262 §16.2.1.6.2/§10.4.6): reads always re-resolve
    // through to the source module's current env value, so a later
    // mutation in the source module is observed by the importer and by
    // the namespace object without any re-copy step. See
    // install_live_binding for the shared implementation.
    for (uint i = 0; i < mod.import_count; i++) {
        ImportEntry* ie = &mod.imports[i];
        if (ie.req_module_idx >= mod.req_module_count) continue;
        ReqModuleEntry* rme = &mod.req_modules[ie.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* source_mod = (ModuleDef*)rme.resolved;

        if (ie.is_star) {
            // `import * as ns from '...'` — build a Module Namespace Object
            HObject*? ns_opt = build_namespace_object(heap, source_mod);
            if (catch err = ns_opt) continue;
            HObject* ns = ns_opt;
            TVal ns_val;
            ns_val.set_object(ns);
            HString* local_key = heap.str_intern(ie.local_name);
            if (local_key != null) {
                env::env_declare(mod.env, local_key, ns_val);
            }
            continue;
        }

        // Resolve the export name to the actual local binding name in the source module.
        // For example, `export default 42` stores the value under "*default*" but
        // exports it under the name "default".
        char[] src_local_name = resolve_export_local_name(source_mod, ie.import_name);
        HString* local_key = heap.str_intern(ie.local_name);
        if (local_key == null) continue;
        install_live_binding(heap, mod.env, local_key, source_mod, src_local_name);
    }

    // Resolve indirect exports (`export { x } from './other'`) as live
    // bindings too — the re-export must observe the ultimate source
    // module's current value, same as a named import.
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect) continue;
        ExportBindingSource src = resolve_export_binding_source(mod, ee);
        if (src.owner == null) continue;
        HString* export_key = heap.str_intern(ee.export_name);
        if (export_key == null) continue;
        install_live_binding(heap, mod.env, export_key, src.owner, src.local_name);
    }

    // Execute module body in its own env. A module compiled with top-level
    // await is async: run it through the async path so `await` suspends and
    // the module's evaluation promise drives to settlement. A rejection (e.g.
    // `await Promise.reject(e)`) surfaces `e` in heap.error_value.
    //
    // heap.current_module_name tracks the module whose body is currently
    // running, so that relative specifiers in a dynamic import() issued from
    // within the body (and not otherwise attributable via vm.current_func)
    // resolve against the right base. Restore the previous value on every
    // exit path.
    char[] saved_module_name = heap.current_module_name;
    heap.current_module_name = mod.module_name;
    defer heap.current_module_name = saved_module_name;

    if (mod.func != null) {
        if (vm.run_depth > 0) {
            // The VM is mid-dispatch (this execute_module call was reached
            // from a dynamic import() handled inline). execute_module_async
            // and execute_in_env take over activations[0]/valstack[0] and are
            // unsafe to call here; execute_module_nested is re-entrant.
            bool? ok = vm.execute_module_nested(mod.func, mod.env);
            if (catch err = ok) return false;
            if (!ok) return false;  // rejected — reason is in heap.error_value
        } else if (mod.func.is_async()) {
            bool? ok = vm.execute_module_async(mod.func, mod.env);
            if (catch err = ok) return false;
            if (!ok) return false;  // rejected — reason is in heap.error_value
        } else {
            TVal? res = vm.execute_in_env(mod.func, mod.env);
            if (catch err = res) {
                return false;
            }
        }
    }

    mod.status = ModuleStatus.EVALUATED;
    call_on_module_evaluated(heap, mod);
    return true;
}

// ============================================================================
// Top-level entry point
// ============================================================================

/// Load, link, and evaluate a module program given its file path.
///
/// `path` is used both to read the top-level module source and as the base
/// name against which relative imports (`./x.js`) are resolved, so it must be
/// the module file's real path (absolute or relative to cwd). Drives the full
/// resolve -> link -> evaluate pipeline.
///
/// Return values (an int rather than a fault so the caller can distinguish
/// the failure kind, mirroring the worker's exec_js contract):
///   0 = evaluated successfully
///   1 = a runtime error was thrown during evaluation of the module or one of
///       its dependencies. The thrown value is left in `heap.error_value` so
///       the caller (e.g. the test harness) can inspect its type.
///   2 = the module (or a dependency) failed to load/compile/link.
fn int run_module_file(Heap* heap, Vm* vm, char[] path) {
    // Reading + compiling + recursively resolving dependencies. A failure here
    // is a load/compile/link error (rc 2), not a thrown runtime value.
    ModuleDef*? mod_opt = resolve_module(heap, path, "");
    if (catch err = mod_opt) { return 2; }
    ModuleDef* mod = mod_opt;

    if (!link_module(heap, vm, mod, vm.global_env)) { return 2; }

    // Evaluation. execute_module returns false when the module body (or a
    // dependency's body) throws; the thrown value persists in heap.error_value
    // (the uncaught-error unwind copies it there). Distinguish "threw at
    // runtime" (rc 1, error_value populated) from a structural failure.
    heap.error_value.set_undefined();
    heap.has_error = false;
    if (!execute_module(heap, vm, mod)) {
        if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
            return 1;  // a value was thrown during evaluation
        }
        return 2;  // structural evaluation failure with no thrown value
    }
    return 0;
}

// ============================================================================
// Dynamic import — `import(specifier)` (ES2020)
// ============================================================================

/// Resolve, link and evaluate the module named by `specifier` and return a
/// Promise (as a TVal carrying one caller-owned reference — the caller must
/// decref after storing it) that fulfills with the module's namespace object
/// or rejects with the module's load/evaluation error. Load and evaluation
/// failures reject the returned promise; a fault means promise allocation
/// itself failed.
///
/// Relative specifiers resolve against the running module's name: the
/// currently executing function's filename when it has one, else
/// heap.current_module_name (maintained by execute_module around body runs).
fn TVal? dynamic_import(Heap* heap, Vm* vm, char[] specifier) {
    HObject*? prom_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return MODULE_ERROR~;
    HObject* prom = prom_raw;
    prom.prototype = heap.promise_proto;
    builtins::promise_init(prom);
    prom.as_header().incref();  // caller-owned reference

    // Duplicate the specifier into heap-owned memory: the incoming slice
    // aliases a JS string's buffer, which can be collected while the
    // ModuleDef caches the normalized name derived from it.
    void* dup_raw = heap.alloc_func(heap.heap_udata, specifier.len);
    if (dup_raw == null) {
        TVal oom_reason = module_type_error(heap, "out of memory resolving module specifier");
        builtins::promise_settle(prom, builtins::PROMISE_REJECTED, &oom_reason, heap);
        builtins::promise_trigger_reactions(prom, heap, (void*)vm);
        TVal oom_result;
        oom_result.set_object(prom);
        return oom_result;
    }
    if (specifier.len > 0) mem::copy(dup_raw, specifier.ptr, (sz)(specifier.len));
    char[] dup_spec = ((char*)dup_raw)[:specifier.len];

    // Base name for relative resolution: the currently executing function's
    // filename when it has one, else the module whose body is currently
    // running (maintained by execute_module around body runs).
    char[] base_name = {};
    if (vm.current_func != null) base_name = vm.current_func.get_filename();
    if (base_name.len == 0) base_name = heap.current_module_name;

    TVal reason;
    bool rejected = false;

    ModuleDef* mod = null;
    ModuleDef*? mod_opt = resolve_module(heap, dup_spec, base_name);
    if (catch err = mod_opt) {
        reason = module_type_error(heap, "cannot resolve module");
        rejected = true;
    } else {
        mod = mod_opt;
    }

    if (!rejected) {
        if (!link_module(heap, vm, mod, vm.global_env)) {
            reason = module_type_error(heap, "cannot link module");
            rejected = true;
        }
    }

    if (!rejected) {
        heap.has_error = false;
        heap.error_value.set_undefined();
        bool ok = execute_module(heap, vm, mod);
        if (!ok) {
            if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
                reason = heap.error_value;
            } else {
                reason = module_type_error(heap, "module evaluation failed");
            }
            rejected = true;
        }
    }

    if (rejected) {
        builtins::promise_settle(prom, builtins::PROMISE_REJECTED, &reason, heap);
        builtins::promise_trigger_reactions(prom, heap, (void*)vm);
        TVal result;
        result.set_object(prom);
        return result;
    }

    HObject*? ns_opt = build_namespace_object(heap, mod);
    TVal fulfill_val;
    if (catch err = ns_opt) {
        fulfill_val = module_type_error(heap, "cannot build module namespace object");
        builtins::promise_settle(prom, builtins::PROMISE_REJECTED, &fulfill_val, heap);
    } else {
        fulfill_val.set_object(ns_opt);
        builtins::promise_settle(prom, builtins::PROMISE_FULFILLED, &fulfill_val, heap);
    }
    builtins::promise_trigger_reactions(prom, heap, (void*)vm);

    TVal result;
    result.set_object(prom);
    return result;
}

// ============================================================================
// Helpers
// ============================================================================

/// Build a TypeError value with the given message, for rejecting a dynamic
/// import promise. On allocation failure returns an undefined TVal — a
/// degraded rejection reason is acceptable since the promise is still
/// rejected.
fn TVal module_type_error(Heap* heap, char[] msg) {
    TVal result;
    HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err = err_raw) {
        result.set_undefined();
        return result;
    }
    HObject* err = err_raw;
    err.prototype = heap.type_err_proto;
    HString* msg_str = heap.str_intern(msg);
    if (msg_str != null) {
        TVal msg_val;
        msg_val.set_string(msg_str);
        HString* msg_key = heap.str_intern("message");
        if (msg_key != null) {
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
    }
    result.set_object(err);
    return result;
}

/// Resolve an export name to the local binding name in a module's exports table.
/// For most exports local_name == export_name, but for `export default <expr>`
/// the compiler emits local_name="*default*" and export_name="default".
fn char[] resolve_export_local_name(ModuleDef* mod, char[] export_name) {
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect && char_slice_eq(ee.export_name, export_name)) {
            return ee.local_name;
        }
    }
    return export_name; // fallback: identity
}

/// Resolve a ModuleDef.exports entry to the module and local binding name
/// that actually OWNS the value — following one level of indirection for
/// `export { x } from './other'` (ee.local_name there names a binding in
/// the OTHER module, not in `mod`'s own env). Direct exports resolve to
/// `mod` itself (with `resolve_export_local_name` applied for the
/// `export default` "*default*" rename). Used by build_namespace_object so
/// every export — direct or re-exported — installs a live accessor against
/// its true owning env, never a same-module self-reference for indirect
/// entries.
///
/// Returns { null, {} } when the indirection's target module isn't
/// resolved (e.g. a load failure) — callers should treat that as
/// "value unavailable" (undefined).
struct ExportBindingSource {
    ModuleDef* owner;
    char[]     local_name;
}
fn ExportBindingSource resolve_export_binding_source(ModuleDef* mod, ExportEntry* ee) {
    if (!ee.is_indirect) {
        return { mod, ee.local_name };
    }
    if (ee.req_module_idx >= mod.req_module_count) {
        return { null, {} };
    }
    ReqModuleEntry* rme = &mod.req_modules[ee.req_module_idx];
    if (rme.resolved == null) {
        return { null, {} };
    }
    ModuleDef* target = (ModuleDef*)rme.resolved;
    char[] target_local = resolve_export_local_name(target, ee.local_name);
    return { target, target_local };
}

/// Install a LIVE binding named `dest_key` in `dest_env`: reading it always
/// re-resolves `src_local_name` in `source_mod.env.bindings` at access time.
/// Shared by named imports, indirect re-exports, and (via
/// build_namespace_object) namespace exports — the one place that answers
/// "read this binding live" for the whole module pipeline.
///
/// Falls back to a plain `undefined` data binding when the source module has
/// no env yet (e.g. a failed dependency), interning fails, or the target
/// would be a direct self-reference (dest_env.bindings/dest_key identical to
/// the source slot — e.g. a self-import of a name this module doesn't
/// actually declare, such as one reachable only via an unresolved `export *`
/// star-export). A self-pointing accessor's getter would call back into
/// itself and recurse forever; since the slot never independently holds a
/// value in that case, `undefined` is the correct (and only sane) result
/// anyway.
fn void install_live_binding(Heap* heap, EnvRecord* dest_env, HString* dest_key,
                              ModuleDef* source_mod, char[] src_local_name) {
    if (source_mod.env == null) {
        TVal undef; undef.set_undefined();
        env::env_declare(dest_env, dest_key, undef);
        return;
    }
    HString* src_key = heap.str_intern(src_local_name);
    if (src_key == null) {
        TVal undef; undef.set_undefined();
        env::env_declare(dest_env, dest_key, undef);
        return;
    }
    if (dest_env.bindings == source_mod.env.bindings && dest_key == src_key) {
        TVal undef; undef.set_undefined();
        env::env_declare(dest_env, dest_key, undef);
        return;
    }
    TVal accessor = builtins::make_module_binding_accessor(heap, source_mod.env.bindings, src_key);
    if (accessor.is_undefined()) {
        // Accessor allocation failed — degrade to a one-time snapshot rather
        // than leaving the binding entirely undeclared.
        TVal? val_opt = env::env_get(source_mod.env, src_key);
        TVal val;
        if (catch err = val_opt) { val.set_undefined(); } else { val = val_opt; }
        env::env_declare(dest_env, dest_key, val);
        return;
    }
    env::env_declare_accessor(dest_env, dest_key, accessor);
}

/// Byte-wise comparison of two identifier slices, used to sort namespace
/// export keys into code-unit order (ECMA-262 §10.4.6.9). UTF-8 byte order
/// agrees with UTF-16 code-unit order for the entire BMP (all codepoints
/// below U+10000); it only diverges from true UTF-16 order for astral
/// export names mixed with codepoints in U+E000-U+FFFF, an accepted edge
/// case in this engine.
fn bool export_name_less(char[] a, char[] b) {
    usz n = a.len < b.len ? a.len : b.len;
    for (usz i = 0; i < n; i++) {
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.len < b.len;
}

/// Build a Module Namespace Object for `import * as ns`.
/// The returned HObject has one own enumerable property per export of
/// source_mod, installed as a LIVE accessor via install_live_binding's
/// shared machinery (make_module_binding_accessor) so a later mutation of
/// the exported binding in source_mod is observed through ns.x /
/// Object.keys(ns) / for-in without re-building the namespace.
///
/// Own string keys are inserted in sorted code-unit order so enumeration
/// (which walks the prop table in insertion order) yields the spec-required
/// sorted order; @@toStringTag is the only symbol key and is added last.
fn HObject*? build_namespace_object(Heap* heap, ModuleDef* source_mod) {
    HObject*? ns_opt = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ns_opt) return MODULE_ERROR~;
    HObject* ns = ns_opt;
    // Module Namespace Exotic Object: [[Prototype]] is always null (ECMA-262 §10.4.6).
    ns.prototype = null;

    // Sort a local index array by export_name (insertion-sort — export
    // counts are small, MAX_EXPORTS=64) rather than mutating source_mod's
    // own exports table.
    uint n = source_mod.export_count;
    uint[MAX_EXPORTS] order;
    for (uint i = 0; i < n; i++) order[i] = i;
    for (uint i = 1; i < n; i++) {
        uint idx = order[i];
        char[] key_i = source_mod.exports[idx].export_name;
        int j = (int)i - 1;
        while (j >= 0 && export_name_less(key_i, source_mod.exports[order[j]].export_name)) {
            order[j + 1] = order[j];
            j--;
        }
        order[j + 1] = idx;
    }

    for (uint oi = 0; oi < n; oi++) {
        ExportEntry* ee = &source_mod.exports[order[oi]];
        HString* export_key = heap.str_intern(ee.export_name);
        if (export_key == null) continue;

        // Resolve to the module/local-name that actually owns the value —
        // follows one level of indirection for `export { x } from './other'`
        // so the accessor never points at a same-module self-reference.
        ExportBindingSource src = resolve_export_binding_source(source_mod, ee);

        TVal accessor;
        accessor.set_undefined();
        if (src.owner != null && src.owner.env != null) {
            HString* local_key = heap.str_intern(src.local_name);
            if (local_key != null) {
                accessor = builtins::make_module_binding_accessor(heap, src.owner.env.bindings, local_key);
            }
        }

        if (accessor.is_undefined()) {
            // Allocation failure or missing env — degrade to a static
            // undefined data property rather than dropping the export key.
            TVal undef; undef.set_undefined();
            ns.put_prop(export_key, undef, hobject::PROP_FLAGS_NEC);
            continue;
        }

        // Export bindings are {enumerable:true, configurable:false} data-view
        // semantics implemented as an accessor per the [[Get]] live-binding
        // requirement; [[Writable]] is meaningless for accessors (the
        // namespace has no [[Set]] — plain field left false by PROP_FLAGS
        // convention below).
        hobject::PropFlags acc_flags = { .writable = false, .enumerable = true, .configurable = false, .is_accessor = true };
        ns.put_prop(export_key, accessor, acc_flags);
    }

    // ns[Symbol.toStringTag] === "Module", {writable:false, enumerable:false, configurable:false}
    // per ECMA-262 §28.3 (Module Namespace Object requirements). Inserted
    // last so it sorts after all string keys per §10.4.6.9 (symbols always
    // follow strings in [[OwnPropertyKeys]] regardless of insertion order).
    HString* tostrtag_sym = builtins::ensure_tostringtag_symbol(heap);
    if (tostrtag_sym != null) {
        TVal tag_val;
        tag_val.set_string(builtins::builtin_intern_string(heap, "Module"));
        ns.put_prop(tostrtag_sym, tag_val, hobject::PROP_FLAGS_NNC);
    }

    return ns;
}

fn bool char_slice_eq(char[] a, char[] b) {
    if (a.len != b.len) return false;
    for (usz i = 0; i < a.len; i++) {
        if (a[i] != b[i]) return false;
    }
    return true;
}
