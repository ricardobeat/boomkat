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
    ERRORED,       // evaluation threw; eval_error holds the cached rejection reason
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
    // True when the import carried `with { type: "json" }`; the referenced
    // module is loaded as a JSON module. Layout mirrors CompReqModuleEntry.
    bool         wants_json;
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

    // import.meta object (ECMA-262 §16.2.1.10 [[ImportMeta]]). A per-module
    // ordinary null-prototype object, lazily created on first `import.meta`
    // access and cached so every evaluation observes the same identity
    // (§13.3.12 Evaluation). Rooted with a ModuleDef-owned reference for the
    // module's lifetime; marked by mark_roots since ModuleDefs live outside
    // the GC-scanned heap.
    HObject*                      import_meta_obj;

    // JSON module support (ES2025 `import x from "m" with { type: "json" }`).
    // A JSON module has no compiled body: `func` is null and its sole export is
    // `default`, bound to `json_value` (the JSON.parse of the file contents,
    // computed at resolve time). `is_json` distinguishes it from an empty JS
    // module so link/execute can install the synthetic default binding.
    bool                          is_json;
    TVal                          json_value;

    // Cached evaluation error (ECMA-262 16.2.1.5 [[EvaluationError]]). When a
    // module body (or a dependency's) throws, the module transitions to ERRORED
    // and the thrown value is stored here with a ModuleDef-owned reference
    // (rooting it for the module's lifetime). Every later Evaluate() of the same
    // module must re-reject with this same value rather than re-running the body.
    bool                          has_eval_error;
    TVal                          eval_error;
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
    // Relative specifier — resolve against base_name's directory. A leading
    // "./" must be stripped in every case (not just when base_name itself
    // has a directory component) so the same file always normalizes to the
    // same identifier regardless of which importer's relative path reached
    // it — e.g. a top-level module loaded as "a.js" (no base directory) and
    // a same-directory sibling's "./a.js" re-export must resolve to the
    // identical cache key, or the module cache treats them as two distinct
    // ModuleDefs: a cyclic self-reference silently gets its own separate,
    // never-evaluated env, whose pre-linked TDZ export bindings then leak
    // into a module-namespace accessor read as a spurious TDZ throw.
    char[] rel = specifier;
    if (rel.len >= 2 && rel[0] == '.' && rel[1] == '/') {
        rel = rel[2..];
    }
    if (base_name.len == 0) return rel;
    // Find last '/' in base_name to get directory
    int last_slash = -1;
    for (usz i = 0; i < base_name.len; i++) {
        if (base_name[i] == '/') last_slash = (int)i;
    }
    if (last_slash < 0) return rel;
    char[] dir = base_name[:last_slash + 1];
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
/// `wants_json` selects the JSON-module load path (parse the file with
/// JSON.parse; sole export is `default`) rather than ECMAScript compilation.
fn ModuleDef*? resolve_module(Heap* heap, char[] specifier, char[] base_name, bool wants_json = false) {
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

    // 4a. JSON module: parse the file with JSON.parse and synthesize a single
    // `default` export = the parsed value (ECMA-262 ParseJSONModule §1.4). The
    // env is created and rooted here so the parsed value survives any GC before
    // link/evaluate. No dependencies, no compiled body.
    if (wants_json) {
        TVal? parsed = builtins::json_parse_module_source(heap, source);
        if (catch err = parsed) {
            // A JSON parse failure surfaces as a resolution-phase SyntaxError.
            return MODULE_ERROR~;
        }
        mod.is_json = true;
        mod.json_value = parsed;
        // Sole export: `default`, a plain (non-lexical, non-indirect) binding.
        mod.exports[0].local_name = "default";
        mod.exports[0].export_name = "default";
        mod.exports[0].is_indirect = false;
        mod.exports[0].req_module_idx = 0;
        mod.exports[0].is_lexical = false;
        mod.export_count = 1;
        // Create + root the env now and declare `default`, so build_namespace_object
        // and install_live_binding see the value even before link_module runs. A
        // JSON module never runs code, so its env needs no scope-chain parent.
        EnvRecord*? env_opt = env::env_create_declarative(heap, null);
        if (catch err = env_opt) return MODULE_ERROR~;
        mod.env = env_opt;
        if (mod.env.bindings != null) {
            heap.register_gc_root(mod.env.bindings.as_header());
        }
        HString* def_key = heap.str_intern("default");
        if (def_key != null) {
            env::env_declare(mod.env, def_key, mod.json_value);
        }
        call_on_module_loaded(heap, mod);
        mod.status = ModuleStatus.LOADED;
        return mod;
    }

    // 5. Compile
    Lexer lex = lexer::lexer_init(source, heap);
    defer lex.free_arena();
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
        // Park a SyntaxError on the heap error channel: a module parse
        // failure is a static-semantics early error, and ECMA-262 requires
        // dynamic `import()` to reject with a SyntaxError rather than a
        // generic load failure. Callers that don't surface the parked value
        // (run_module_file's rc-2 path) clear the channel themselves.
        heap.error_value = module_syntax_error(
            heap, msg_len > 0 ? ((char*)msg)[:msg_len] : (char[])"module compile error");
        heap.has_error = true;
        return MODULE_ERROR~;
    }
    mod.func = func_opt;
    // Stamp the normalized module name onto the whole compiled-function tree
    // (body + every nested function template). `import.meta` resolves its owning
    // module from the currently executing function's filename, so nested
    // functions must carry it too (GetActiveScriptOrModule / §13.3.12 must
    // observe the DEFINING module, not the one whose body happens to be running).
    stamp_module_filename(mod.func, normalized.ptr, (uint)normalized.len);

    // 6. Notify host
    call_on_module_loaded(heap, mod);

    // 7. Recursively resolve dependencies
    for (uint i = 0; i < mod.req_module_count; i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        ModuleDef*? dep = resolve_module(heap, rme.module_name, normalized, rme.wants_json);
        if (catch err = dep) {
            return MODULE_ERROR~;
        }
        rme.resolved = dep;
    }

    mod.status = ModuleStatus.LOADED;
    return mod;
}

// ResolveExport (ECMA-262 16.2.1.6.3) outcome. NULL means the name is not
// resolvable (either genuinely absent or a circular self-reference detected via
// the resolveSet); AMBIGUOUS means two or more `export *` stars provide the name
// from distinct bindings. Both are static-semantics (SyntaxError) failures when
// they occur for an indirect export.
enum ResolveExportKind : char {
    RESOLVED,
    NULL,
    AMBIGUOUS,
}
struct ResolveExportResult {
    ResolveExportKind kind;
    ModuleDef*        owner;        // owning module (RESOLVED only)
    char[]            binding_name; // local binding name in `owner` (RESOLVED only)
}

const uint RESOLVE_SET_MAX = 64;
struct ResolveSetEntry {
    ModuleDef* owner_mod;
    char[]     export_name;
}

/// ResolveExport(exportName, resolveSet) — ECMA-262 16.2.1.6.3 for a
/// SourceTextModuleRecord. Returns a resolution binding, or NULL/AMBIGUOUS.
/// `set`/`set_len` carry the resolveSet across the recursion to break circular
/// import requests (step 2: if the same {module, exportName} is already in the
/// set, this is a circular request → NULL).
fn ResolveExportResult resolve_export(ModuleDef* mod, char[] export_name,
                                      ResolveSetEntry* set, uint set_len) {
    // Step 2: circular-request guard.
    for (uint i = 0; i < set_len; i++) {
        if (set[i].owner_mod == mod && char_slice_eq(set[i].export_name, export_name)) {
            return { ResolveExportKind.NULL, null, {} };
        }
    }
    if (set_len < RESOLVE_SET_MAX) {
        set[set_len] = { mod, export_name };
        set_len++;
    }

    // Step 4: local (direct, non-indirect) exports own their binding in `mod`.
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (ee.is_indirect) continue;
        if (char_slice_eq(ee.export_name, export_name)) {
            return { ResolveExportKind.RESOLVED, mod, ee.local_name };
        }
    }

    // Step 5: indirect exports (`export { x } from './other'`). Delegate to the
    // imported module's ResolveExport for the re-exported name.
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect) continue;
        if (!char_slice_eq(ee.export_name, export_name)) continue;
        if (ee.req_module_idx >= mod.req_module_count) return { ResolveExportKind.NULL, null, {} };
        ReqModuleEntry* rme = &mod.req_modules[ee.req_module_idx];
        if (rme.resolved == null) return { ResolveExportKind.NULL, null, {} };
        ModuleDef* imported = (ModuleDef*)rme.resolved;
        // `export * as ns from` (local name "*") resolves to the imported
        // module's NAMESPACE object itself (§16.2.1.6.3 step 6.b), not to a
        // binding inside it.
        if (char_slice_eq(ee.local_name, "*")) {
            return { ResolveExportKind.RESOLVED, imported, "*" };
        }
        // `export { x } from` re-exports the name `ee.local_name` from `imported`.
        return resolve_export(imported, ee.local_name, set, set_len);
    }

    // Step 6: `default` is never provided by `export *`.
    if (char_slice_eq(export_name, "default")) {
        return { ResolveExportKind.NULL, null, {} };
    }

    // Step 7-8: star exports (`export * from './z'`). Gather resolutions from
    // every star target; multiple distinct bindings for the same name are
    // AMBIGUOUS.
    ResolveExportResult star_resolution = { ResolveExportKind.NULL, null, {} };
    for (uint i = 0; i < mod.star_export_count; i++) {
        StarExportEntry* se = &mod.star_exports[i];
        if (se.req_module_idx >= mod.req_module_count) continue;
        ReqModuleEntry* rme = &mod.req_modules[se.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* imported = (ModuleDef*)rme.resolved;
        ResolveExportResult r = resolve_export(imported, export_name, set, set_len);
        if (r.kind == ResolveExportKind.AMBIGUOUS) return r;
        if (r.kind == ResolveExportKind.RESOLVED) {
            if (star_resolution.kind == ResolveExportKind.NULL) {
                star_resolution = r;
            } else if (star_resolution.owner != r.owner ||
                       !char_slice_eq(star_resolution.binding_name, r.binding_name)) {
                return { ResolveExportKind.AMBIGUOUS, null, {} };
            }
        }
    }
    return star_resolution;
}

/// Validate a module's indirect exports (ECMA-262 16.2.1.6.2
/// InitializeEnvironment step 4): each `export { x } from './y'` must resolve to
/// exactly one binding. A NULL or AMBIGUOUS resolution is a SyntaxError. On
/// failure parks a SyntaxError on the heap error channel and returns false.
fn bool validate_indirect_exports(Heap* heap, ModuleDef* mod) {
    for (uint i = 0; i < mod.export_count; i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect) continue;
        ResolveSetEntry[RESOLVE_SET_MAX] set;
        ResolveExportResult r = resolve_export(mod, ee.export_name, &set[0], 0);
        if (r.kind != ResolveExportKind.RESOLVED) {
            TVal se = module_syntax_error(heap,
                "indirect export does not resolve to a single binding");
            heap.error_value.set_undefined();
            heap.tval_copy_ref(&heap.error_value, &se);
            heap.has_error = true;
            return false;
        }
    }
    return true;
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

    // A JSON module has no body and no dependencies; its env (holding the sole
    // `default` binding) is created and rooted at resolve time. Just validate
    // that no importer requests a named binding other than `default` (JSON
    // modules define no named bindings — ECMA-262; `import {x}` must be a
    // resolution-phase SyntaxError) and mark it linked.
    if (mod.is_json) {
        mod.status = ModuleStatus.LINKED;
        return true;
    }

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

    // Static-semantics validation of indirect exports (16.2.1.6.2 step 4):
    // every `export { x } from './y'` must resolve to exactly one binding. A
    // NULL (circular / absent) or AMBIGUOUS resolution is a SyntaxError, parked
    // on the heap error channel for dynamic_import to surface as the rejection.
    if (!validate_indirect_exports(heap, mod)) return false;

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

        // A JSON module exports only `default`; importing any other named
        // binding from it is a resolution-phase SyntaxError (ECMA-262: JSON
        // modules define no named bindings). Fail the link so run_module_file
        // reports it as a load/resolution error.
        if (source_mod.is_json && !char_slice_eq(ie.import_name, "default")) {
            return false;
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

    // NOTE: an indirect export (`export { x } from './other'`) installs NO
    // binding in mod.env at link time either — see the matching note in
    // execute_module for why a re-exported name must never become a
    // resolvable identifier inside the re-exporting module's own body.

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

/// Record a module's evaluation error and mark it ERRORED. The thrown value is
/// captured out of the heap error channel with a ModuleDef-owned reference so it
/// survives GC and can re-reject every later Evaluate() of the same module.
/// Leaves the error channel populated (the caller still surfaces the throw for
/// the current evaluation). Always returns false for use in `return`.
fn bool module_record_eval_error(Heap* heap, ModuleDef* mod) {
    mod.status = ModuleStatus.ERRORED;
    if (!mod.has_eval_error) {
        mod.eval_error.set_undefined();
        if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
            heap.tval_copy_ref(&mod.eval_error, &heap.error_value);
        }
        mod.has_eval_error = true;
    }
    return false;
}

/// Execute a module: run dependencies first, then resolve imports, then run body.
fn bool execute_module(Heap* heap, Vm* vm, ModuleDef* mod) {
    if (mod.status == ModuleStatus.EVALUATED) return true;
    // A module whose evaluation previously threw must re-reject with the SAME
    // cached error (ECMA-262 16.2.1.5.1 step 5). Restore it into the error
    // channel and report failure without re-running the body.
    if (mod.status == ModuleStatus.ERRORED) {
        heap.error_value.set_undefined();
        heap.tval_copy_ref(&heap.error_value, &mod.eval_error);
        heap.has_error = true;
        return false;
    }
    if (mod.status == ModuleStatus.EVALUATING) return true; // cycle guard

    // A JSON module has no body to run; its `default` binding was installed at
    // resolve time. Nothing to evaluate.
    if (mod.is_json) {
        mod.status = ModuleStatus.EVALUATED;
        call_on_module_evaluated(heap, mod);
        return true;
    }

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
            if (!execute_module(heap, vm, dep)) return module_record_eval_error(heap, mod);
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
                env::env_declare_const(mod.env, local_key, ns_val);
            }
            continue;
        }

        // Resolve the export name to its OWNING module and local binding
        // name via the full ResolveExport algorithm (ECMA-262 16.2.1.6.3):
        // a plain `resolve_export_local_name` only checks direct exports, so
        // a name reachable only through `export * from` (star re-export,
        // possibly through a cyclic chain that ResolveExport must skip) was
        // never found and silently installed as an undefined accessor onto
        // `source_mod` itself. ResolveExport also follows one-hop indirect
        // (`export { x } from`) re-exports, so this subsumes the old
        // identity-fallback behavior for direct exports too.
        HString* local_key = heap.str_intern(ie.local_name);
        if (local_key == null) continue;
        ResolveSetEntry[RESOLVE_SET_MAX] rset;
        ResolveExportResult rr = resolve_export(source_mod, ie.import_name, &rset[0], 0);
        if (rr.kind == ResolveExportKind.RESOLVED && rr.owner != null) {
            if (char_slice_eq(rr.binding_name, "*")) {
                // `export * as ns from` resolved through a re-export chain:
                // the import observes the target module's namespace object.
                HObject*? ns_opt = build_namespace_object(heap, rr.owner);
                if (try ns = ns_opt) {
                    TVal ns_val; ns_val.set_object(ns);
                    env::env_declare(mod.env, local_key, ns_val);
                } else {
                    TVal undef; undef.set_undefined();
                    env::env_declare(mod.env, local_key, undef);
                }
            } else {
                install_live_binding(heap, mod.env, local_key, rr.owner, rr.binding_name);
            }
        } else {
            // Unresolvable (null/ambiguous) — fall back to the old identity
            // resolution against the direct source module so a same-module
            // self-import or an already-flagged link error still gets a
            // (possibly undefined) binding instead of none at all.
            char[] src_local_name = resolve_export_local_name(source_mod, ie.import_name);
            install_live_binding(heap, mod.env, local_key, source_mod, src_local_name);
        }
    }

    // NOTE: an indirect export (`export { x } from './other'`) intentionally
    // installs NO binding in mod.env — ECMA-262 §16.2.1.6.2 InitializeEnvironment
    // only creates bindings for ImportEntries and local (non-indirect)
    // ExportEntries; a re-exported name is never a resolvable identifier
    // inside the re-exporting module's own body (it is only observable
    // externally via ResolveExport / the module's namespace object, both of
    // which resolve indirect exports directly through the export-entry
    // metadata — see resolve_export and resolve_export_binding_source).
    // Declaring it here as a live accessor used to make it a spurious local
    // identifier: an internal `B;` reference (where `export { A as B } from
    // './x'` re-exports a not-yet-initialized `A`) would incorrectly resolve
    // through this binding as a TDZ read instead of an unresolved-reference
    // ReferenceError, and — because the accessor's getter runs via
    // vm.heap.call_fn's re-entrant nested Vm.run (vm_call_fn_impl) — a TDZ
    // throw surfacing from a SECOND read of that same accessor inside an
    // enclosing catch handler (e.g. `catch (e) { arr.push(e.name, typeof B) }`)
    // would escape past the still-live outer catcher instead of propagating
    // as the plain uncaught-reference behavior real engines produce.

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
            if (catch err = ok) return module_record_eval_error(heap, mod);
            if (!ok) return module_record_eval_error(heap, mod);  // rejected — reason is in heap.error_value
        } else if (mod.func.is_async()) {
            bool? ok = vm.execute_module_async(mod.func, mod.env);
            if (catch err = ok) return module_record_eval_error(heap, mod);
            if (!ok) return module_record_eval_error(heap, mod);  // rejected — reason is in heap.error_value
        } else {
            TVal? res = vm.execute_in_env(mod.func, mod.env);
            if (catch err = res) {
                return module_record_eval_error(heap, mod);
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
    if (catch err = mod_opt) {
        // resolve_module may have parked a SyntaxError on the error channel
        // for dynamic import's benefit; here the failure is reported via the
        // return code, so clear the channel to keep the rc-2 contract
        // (structural failure, no thrown value).
        heap.error_value.set_undefined();
        heap.has_error = false;
        return 2;
    }
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
/// Capture the current thrown value out of every error channel into a
/// caller-owned `*out` and clear the channels, so a pending fault does not
/// leak past the point where it is turned into a promise rejection. When no
/// value is present, `*out` is set to a fresh TypeError with `fallback_msg`.
fn void capture_and_clear_error(Heap* heap, Vm* vm, TVal* out, char[] fallback_msg) {
    if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
        out.set_undefined();
        heap.tval_copy_ref(out, &heap.error_value);
    } else {
        *out = module_type_error(heap, fallback_msg);
    }
    heap.error_value.set_undefined();
    heap.has_error = false;
    vm.throw_pending = false;
    vm.throw_value.set_undefined();
}

/// Validate the ES2025 import-call options argument and its `with` attributes
/// (§13.3.10 EvaluateImportCall / GetImportAttributes). Returns true on
/// success. On any abrupt completion (non-object options/with, a throwing
/// `with` getter or `ownKeys`, or a non-String attribute value) returns false
/// with `*reason` set to a caller-owned rejection value and every error
/// channel cleared. `options` may be undefined (no attributes → success).
///
/// Attributes are validated but not otherwise applied: this engine's loader
/// carries no per-attribute behavior beyond the already-supported JSON module
/// type inferred from the specifier, so a well-formed `with` clause is a
/// no-op here (matching the module resolution level already in place).
fn bool validate_import_options(Heap* heap, Vm* vm, TVal* options, TVal* reason, bool* wants_json) {
    *wants_json = false;
    if (options.is_undefined()) return true;
    if (!options.is_object()) {
        *reason = module_type_error(heap, "import options must be an object");
        return false;
    }
    HObject* opts_obj = (HObject*)options.get_heapptr();
    if (opts_obj == null) return true;

    // attributesObj = Get(options, "with")
    HString* with_key = heap.str_intern("with");
    if (with_key == null) return true;
    TVal with_val;
    with_val.set_undefined();
    if (!builtins::js_get((void*)vm, heap, opts_obj, with_key, &with_val)) {
        capture_and_clear_error(heap, vm, reason, "import options getter threw");
        return false;
    }
    if (with_val.is_undefined()) return true;
    if (!with_val.is_object()) {
        *reason = module_type_error(heap, "import 'with' must be an object");
        return false;
    }
    HObject* with_obj = (HObject*)with_val.get_heapptr();
    if (with_obj == null) return true;

    // keys = OwnPropertyKeys(attributesObj) — proxy `ownKeys` may throw.
    HObject* keys_arr = null;
    HString** ord_keys = null;
    uint n = 0;
    if (with_obj.flags.exotic_proxyobj) {
        if (!builtins::proxy_mop_own_keys((void*)vm, heap, with_obj, &keys_arr)) {
            capture_and_clear_error(heap, vm, reason, "import 'with' ownKeys threw");
            return false;
        }
        n = keys_arr != null ? keys_arr.array_used : 0;
    } else {
        n = builtins::ordinary_own_keys(heap, with_obj, &ord_keys);
    }

    bool ok = true;
    for (uint i = 0; i < n; i++) {
        HString* key = null;
        if (keys_arr != null) {
            TVal? kv_opt = keys_arr.get_array_idx(i);
            if (catch e = kv_opt) continue;
            TVal kv = kv_opt;
            if (!kv.is_string()) continue;
            key = (HString*)kv.get_heapptr();
        } else {
            key = ord_keys[i];
        }
        if (key == null) continue;
        // Only String keys participate; a Symbol is a STRING-tagged HString
        // with is_symbol set — skip it (and never invoke its getter).
        if (key.is_symbol()) continue;

        // Only enumerable String-keyed own properties participate
        // (EnumerableOwnProperties). getOwnPropertyDescriptor may be a proxy
        // trap that throws.
        builtins::ProxyDesc desc;
        if (!builtins::own_property_desc((void*)vm, heap, with_obj, key, &desc)) {
            capture_and_clear_error(heap, vm, reason, "import 'with' descriptor threw");
            ok = false;
            break;
        }
        if (!desc.found || !desc.enumerable) continue;

        // value = Get(attributesObj, key); a getter may throw.
        TVal av;
        av.set_undefined();
        if (!builtins::js_get((void*)vm, heap, with_obj, key, &av)) {
            capture_and_clear_error(heap, vm, reason, "import 'with' value getter threw");
            ok = false;
            break;
        }
        // A Symbol is a STRING-tagged HString with is_symbol set; it is not a
        // String value and must reject.
        bool is_str_value = av.is_string();
        if (is_str_value) {
            HString* avs = (HString*)av.get_heapptr();
            if (avs != null && avs.is_symbol()) is_str_value = false;
        }
        if (!is_str_value) {
            *reason = module_type_error(heap, "import attribute value must be a string");
            ok = false;
            break;
        }
        // Recognize the `type: "json"` attribute so the loader parses the
        // referenced file as a JSON module (ES2025). Other attributes are
        // accepted (well-formed) but carry no loader behavior here.
        if (char_slice_eq(key.get_data(), "type")) {
            HString* avs2 = (HString*)av.get_heapptr();
            if (avs2 != null && char_slice_eq(avs2.get_data(), "json")) {
                *wants_json = true;
            }
        }
    }

    if (ord_keys != null) heap.free_func(heap.heap_udata, ord_keys);
    return ok;
}

/// Build a Promise (as a TVal carrying one caller-owned reference — the caller
/// must decref after storing it) already rejected with `reason`. Used by the
/// DYN_IMPORT opcode for the IfAbruptRejectPromise steps of §13.3.10: an abrupt
/// completion from evaluating the specifier or from ToString(specifier) does
/// not throw synchronously — it rejects the returned promise. On promise
/// allocation failure returns a fault.
fn TVal? dynamic_import_reject(Heap* heap, Vm* vm, TVal* reason) {
    HObject*? prom_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return MODULE_ERROR~;
    HObject* prom = prom_raw;
    prom.prototype = heap.promise_proto;
    builtins::promise_init(prom);
    prom.as_header().incref();  // caller-owned reference
    builtins::promise_settle(prom, builtins::PROMISE_REJECTED, reason, heap);
    builtins::promise_trigger_reactions(prom, heap, (void*)vm);
    TVal result;
    result.set_object(prom);
    return result;
}

fn TVal? dynamic_import(Heap* heap, Vm* vm, char[] specifier, bool wants_json = false) {
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
    reason.set_undefined();
    bool rejected = false;
    // True when `reason` holds a reference we own (copied out of an error
    // channel) that must be dropped after promise_settle increfs its own copy.
    bool clear_reason_ref = false;

    ModuleDef* mod = null;
    heap.has_error = false;
    heap.error_value.set_undefined();
    ModuleDef*? mod_opt = resolve_module(heap, dup_spec, base_name, wants_json);
    if (catch err = mod_opt) {
        // A load failure may have parked a specific static-semantics error
        // (SyntaxError for a module parse failure) on the heap error channel —
        // prefer it over the generic TypeError, and clear the channel so the
        // fault becomes a promise rejection rather than leaking to the
        // enclosing frame.
        if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
            reason.set_undefined();
            heap.tval_copy_ref(&reason, &heap.error_value);
            clear_reason_ref = true;
        } else {
            reason = module_type_error(heap, "cannot resolve module");
        }
        heap.error_value.set_undefined();
        heap.has_error = false;
        rejected = true;
    } else {
        mod = mod_opt;
    }

    if (!rejected) {
        heap.has_error = false;
        heap.error_value.set_undefined();
        if (!link_module(heap, vm, mod, vm.global_env)) {
            // A link failure may have parked a specific static-semantics error
            // (SyntaxError for an ambiguous/circular indirect export) on the
            // heap error channel — prefer it over the generic TypeError, and
            // clear the channel so the fault becomes a promise rejection rather
            // than leaking to the enclosing frame.
            if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
                reason.set_undefined();
                heap.tval_copy_ref(&reason, &heap.error_value);
                clear_reason_ref = true;
            } else {
                reason = module_type_error(heap, "cannot link module");
            }
            heap.error_value.set_undefined();
            heap.has_error = false;
            rejected = true;
        }
    }

    if (!rejected) {
        heap.has_error = false;
        heap.error_value.set_undefined();
        bool ok = execute_module(heap, vm, mod);
        if (!ok) {
            if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
                // Take ownership of the thrown value: copy it out, then clear
                // every error channel so the VM does not see a lingering fault
                // once dynamic_import returns the (rejected) promise. Without
                // this the enclosing script/module observes a spurious uncaught
                // throw right after `import(x)` returns.
                reason.set_undefined();
                heap.tval_copy_ref(&reason, &heap.error_value);
                heap.error_value.set_undefined();
                heap.has_error = false;
                vm.throw_pending = false;
                vm.throw_value.set_undefined();
                clear_reason_ref = true;
            } else {
                reason = module_type_error(heap, "module evaluation failed");
            }
            rejected = true;
        }
    }

    if (rejected) {
        builtins::promise_settle(prom, builtins::PROMISE_REJECTED, &reason, heap);
        if (clear_reason_ref) heap.decref_tval(&reason);
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
    return module_error_with_proto(heap, heap.type_err_proto, msg);
}

/// Build a SyntaxError value for a module static-semantics failure (a link-phase
/// early error such as an ambiguous or circular indirect export). ECMA-262
/// surfaces these as SyntaxError.
fn TVal module_syntax_error(Heap* heap, char[] msg) {
    return module_error_with_proto(heap, heap.syntax_err_proto, msg);
}

fn TVal module_error_with_proto(Heap* heap, HObject* proto, char[] msg) {
    TVal result;
    HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err = err_raw) {
        result.set_undefined();
        return result;
    }
    HObject* err = err_raw;
    err.prototype = proto;
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

/// One resolved exported name contributing to a namespace object's own keys.
/// `entry` is the owning module's ExportEntry when the name comes from a direct
/// or indirect export (used to follow `export {x} from` / `export * as ns`
/// indirection); it is null for a name reached purely through a `export *` star
/// re-export, in which case `local_name` names a binding directly in `owner_mod`.
struct NsExportItem {
    char[]     export_name;
    ModuleDef* owner_mod;
    char[]     local_name;
    ExportEntry* entry;
}

const uint MAX_NS_EXPORTS = 128;

/// True if `name` is already among the first `count` collected namespace items.
fn bool ns_has_export_name(NsExportItem[MAX_NS_EXPORTS]* items, uint count, char[] name) {
    for (uint i = 0; i < count; i++) {
        if (char_slice_eq((*items)[i].export_name, name)) return true;
    }
    return false;
}

/// Append a namespace export item unless its name is already present (nearer
/// exports shadow star-reached ones) or the table is full.
fn void ns_add_export_item(NsExportItem[MAX_NS_EXPORTS]* items, uint* count,
                           char[] export_name, ModuleDef* owner_mod, ExportEntry* entry) {
    if (*count >= MAX_NS_EXPORTS) return;
    if (ns_has_export_name(items, *count, export_name)) return;
    (*items)[*count] = { export_name, owner_mod, entry != null ? entry.local_name : export_name, entry };
    (*count)++;
}

/// Expand `export *` star re-exports (§16.2.3.7 GetExportedNames) into the
/// namespace item list, transitively. For each star-target module, every one of
/// its exported names EXCEPT `default` is added (if not already present) as a
/// live binding into that target's own env — direct exports keep their owning
/// ExportEntry (so indirect/namespace re-exports still resolve correctly),
/// while names the target itself only re-exports via its own `export *` are
/// added as plain bindings in the target. `depth` guards against import cycles.
fn void collect_star_export_items(ModuleDef* mod, NsExportItem[MAX_NS_EXPORTS]* items,
                                  uint* count, uint depth) {
    collect_star_export_items_from(mod, mod, items, count, depth);
}

/// Implementation of collect_star_export_items: `root` is the module whose
/// namespace is being built (fixed across the whole recursion — GetModuleNamespace
/// always resolves ambiguity relative to it, ECMA-262 §16.2.1.6.3), `mod` is
/// the current module being scanned for `export *` targets.
fn void collect_star_export_items_from(ModuleDef* root, ModuleDef* mod,
                                       NsExportItem[MAX_NS_EXPORTS]* items,
                                       uint* count, uint depth) {
    if (depth > MAX_STAR_EXPORTS) return;
    for (uint si = 0; si < mod.star_export_count; si++) {
        StarExportEntry* se = &mod.star_exports[si];
        if (se.req_module_idx >= mod.req_module_count) continue;
        ReqModuleEntry* rme = &mod.req_modules[se.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* target = (ModuleDef*)rme.resolved;
        for (uint ei = 0; ei < target.export_count; ei++) {
            ExportEntry* ee = &target.exports[ei];
            // `export *` never re-exports the default binding (§16.2.3.7 step 4).
            if (char_slice_eq(ee.export_name, "default")) continue;
            // A name reached through TWO OR MORE distinct star paths with
            // different owning bindings is ambiguous (§16.2.1.6.3 steps
            // 9-10) and must be OMITTED from the namespace object entirely
            // — not resolved to whichever star export happened to be
            // visited first.
            ResolveSetEntry[RESOLVE_SET_MAX] amb_rset;
            ResolveExportResult amb_rr = resolve_export(root, ee.export_name, &amb_rset[0], 0);
            if (amb_rr.kind == ResolveExportKind.AMBIGUOUS) continue;
            ns_add_export_item(items, count, ee.export_name, target, ee);
        }
        // Transitively include the target's own star re-exports.
        collect_star_export_items_from(root, target, items, count, depth + 1);
    }
}

/// Recursively set filename_ptr/filename_len on a compiled function and every
/// nested function template it contains. Used to attribute each function to its
/// defining module so `import.meta` (§13.3.12) resolves correctly from within
/// nested functions.
fn void stamp_module_filename(bytecode::CompiledFunction* func, char* name_ptr, uint name_len) {
    if (func == null) return;
    func.filename_ptr = name_ptr;
    func.filename_len = name_len;
    for (uint i = 0; i < func.inner_count; i++) {
        stamp_module_filename(func.inner_funcs[i], name_ptr, name_len);
    }
}

/// Return the import.meta object for `mod`, creating it on first access
/// (ECMA-262 §13.3.12 ImportMeta Evaluation + §16.2.1.10 [[ImportMeta]]).
///
/// The object is an ordinary object with a null [[Prototype]] (matching the
/// HostGetImportMetaProperties conventions the test262 corpus assumes) and a
/// single host-provided `url` data property (writable/enumerable/configurable)
/// holding the module's normalized name. It is cached on the ModuleDef so every
/// evaluation of the module observes the same identity, and distinct modules
/// get distinct objects. The cache holds a ModuleDef-owned reference (rooted by
/// mark_roots) for the module's lifetime.
fn HObject*? get_import_meta(Heap* heap, ModuleDef* mod) {
    if (mod.import_meta_obj != null) return mod.import_meta_obj;

    HObject*? meta_opt = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = meta_opt) return MODULE_ERROR~;
    HObject* meta = meta_opt;
    // §13.3.12 step 4.a: importMeta is OrdinaryObjectCreate(null).
    meta.prototype = null;

    // HostGetImportMetaProperties: the sole host property is `url`, the
    // module's resolved name (our normalized module path).
    HString* url_str = heap.str_intern(mod.module_name);
    if (url_str != null) {
        TVal url_val;
        url_val.set_string(url_str);
        HString* url_key = heap.str_intern("url");
        if (url_key != null) {
            meta.put_prop(url_key, url_val, hobject::PROP_FLAGS_WEC);
        }
    }

    // Root for the module's lifetime and cache for identity.
    meta.as_header().incref();
    mod.import_meta_obj = meta;
    return meta;
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
    // A module has exactly one Module Namespace Object (ECMA-262 §10.4.6.12
    // GetModuleNamespace: cached in module.[[Namespace]]). Repeated `import * as`
    // / dynamic imports of the same module must observe the SAME object
    // identity — build it once and cache it on the ModuleDef.
    if (source_mod.namespace_obj != null) {
        return source_mod.namespace_obj;
    }
    HObject*? ns_opt = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ns_opt) return MODULE_ERROR~;
    HObject* ns = ns_opt;
    // Module Namespace Exotic Object: [[Prototype]] is always null (ECMA-262 §10.4.6).
    ns.prototype = null;
    // Mark as a Module Namespace Exotic Object so the reflective MOP builtins
    // present exports as DATA descriptors and propagate TDZ ReferenceErrors
    // (see ObjFlags.exotic_module_ns).
    ns.flags.exotic_module_ns = true;

    // Cache for identity BEFORE populating exports: a self-referential
    // `export * as ns from './self'` (or a cyclic star-as re-export) would
    // otherwise recurse into build_namespace_object for the same module and
    // never terminate. Caching now means the recursive call returns this
    // in-progress (still-empty) object — matching the spec's single
    // GetModuleNamespace object per module. Root it for the ModuleDef's lifetime.
    ns.as_header().incref();
    source_mod.namespace_obj = ns;

    // Collect the full exported-name set (§10.4.6.9 [[OwnPropertyKeys]] iterates
    // GetExportedNames): the module's own direct/indirect exports plus the names
    // reached transitively through `export *` star re-exports. `default` is
    // never re-exported by a star (§16.2.3.7). Names already contributed by a
    // nearer export win (star names are only added if not already present).
    NsExportItem[MAX_NS_EXPORTS] items;
    uint item_count = 0;
    for (uint i = 0; i < source_mod.export_count; i++) {
        ExportEntry* ee = &source_mod.exports[i];
        ns_add_export_item(&items, &item_count, ee.export_name, source_mod, ee);
    }
    collect_star_export_items(source_mod, &items, &item_count, 0);

    // Sort collected items by export_name into code-unit order (§10.4.6.9).
    for (uint i = 1; i < item_count; i++) {
        NsExportItem tmp = items[i];
        int j = (int)i - 1;
        while (j >= 0 && export_name_less(tmp.export_name, items[j].export_name)) {
            items[j + 1] = items[j];
            j--;
        }
        items[j + 1] = tmp;
    }

    for (uint oi = 0; oi < item_count; oi++) {
        NsExportItem* it = &items[oi];
        HString* export_key = heap.str_intern(it.export_name);
        if (export_key == null) continue;

        // Namespace re-export (`export * as ns from './other'`): the export
        // entry's local name is "*", meaning the exported value is the TARGET
        // module's own namespace object (built recursively), installed as a
        // static data property {enumerable:true, configurable:false} — not a
        // live env binding accessor. (§16.2.3.7 / GetModuleNamespace.)
        if (it.entry != null && it.entry.is_indirect && char_slice_eq(it.entry.local_name, "*")
            && it.entry.req_module_idx < it.owner_mod.req_module_count) {
            ReqModuleEntry* rme = &it.owner_mod.req_modules[it.entry.req_module_idx];
            if (rme.resolved != null) {
                ModuleDef* target = (ModuleDef*)rme.resolved;
                HObject*? nested_opt = build_namespace_object(heap, target);
                if (catch nerr = nested_opt) {
                    TVal undef; undef.set_undefined();
                    ns.put_prop(export_key, undef, hobject::PROP_FLAGS_NEC);
                    continue;
                }
                TVal nested_tv; nested_tv.set_object(nested_opt);
                ns.put_prop(export_key, nested_tv, hobject::PROP_FLAGS_NEC);
                continue;
            }
            TVal undef; undef.set_undefined();
            ns.put_prop(export_key, undef, hobject::PROP_FLAGS_NEC);
            continue;
        }

        // Resolve to the module/local-name that actually owns the value via
        // the full ResolveExport algorithm (ECMA-262 16.2.1.6.3): an item
        // reached through `export { x } from` may itself point at an
        // indirect or star-only export in the target module (a re-export
        // chain, possibly cyclic back through this very module), and a
        // single level of indirection is not enough to reach the true owner
        // — see the analogous named-import fix above.
        ExportBindingSource src = { null, {} };
        ResolveSetEntry[RESOLVE_SET_MAX] ns_rset;
        ResolveExportResult ns_rr = resolve_export(it.owner_mod, it.export_name, &ns_rset[0], 0);
        if (ns_rr.kind == ResolveExportKind.RESOLVED && ns_rr.owner != null
            && !char_slice_eq(ns_rr.binding_name, "*")) {
            src = { ns_rr.owner, ns_rr.binding_name };
        } else if (it.entry != null) {
            src = resolve_export_binding_source(it.owner_mod, it.entry);
        } else {
            // Star-reached name with no ExportEntry: it names a binding in the
            // star-target module directly (see collect_star_export_items).
            src = { it.owner_mod, it.local_name };
        }

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

    // Module namespace exotic objects are not extensible (ECMA-262 §10.4.6):
    // [[IsExtensible]] always returns false and [[PreventExtensions]] is a
    // no-op success. Set the flag after all own properties are installed.
    ns.flags.extensible = false;

    return ns;
}

fn bool char_slice_eq(char[] a, char[] b) {
    if (a.len != b.len) return false;
    for (usz i = 0; i < a.len; i++) {
        if (a[i] != b[i]) return false;
    }
    return true;
}
