// The ESM module system: data structures, host API, loader, and linker.
//
// A module moves through five stages:
//   1. Compile: compile_module() parses the import and export clauses and emits
//      bytecode into a ModuleDef.
//   2. Resolve: every transitive dependency is compiled the same way.
//   3. Link: modules share env bindings, which is what makes exports live.
//   4. Execute: the module body's top-level statements run.
//   5. Namespace: `import *` builds a Module Namespace Object.
module boomkat::esm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::env;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::lexer;
import boomkat::compiler;
import boomkat::builtins;
import boomkat::vm;
import std::io;
import std::collections::list;

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
    EVALUATING,    // being executed; still on the DFS stack
    // ECMA-262 ~evaluating-async~: the DFS traversal of this module is
    // COMPLETE (it has left the stack and its component has a cycle root), but
    // its body has not finished -- either it is suspended on a top-level await,
    // or it is waiting for async dependencies to finish. Distinct from
    // EVALUATING because a module in this state is no longer a cycle ancestor:
    // an importer reaching it must WAIT for it, not treat it as part of its
    // own strongly-connected component.
    EVALUATING_ASYNC,
    EVALUATED,     // fully executed
    ERRORED,       // evaluation threw; eval_error holds the cached rejection reason
}
// ECMA-262 [[AsyncEvaluationOrder]]. UNSET before a module is known to be
// async; ORDERED once it is, with async_eval_index holding its position in the
// agent-wide sequence; DONE once its body has finished.
enum AsyncEvalOrder : char {
    UNSET,
    ORDERED,
    DONE,
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
    // True for `import defer * as ns` (ES2025 import-defer): the binding gets
    // a Deferred Module Namespace Exotic Object and the edge does not force
    // the target's evaluation. Layout must match CompImportEntry.
    bool   is_deferred;
}

struct ExportEntry {
    char[] local_name;      // the local binding name
    char[] export_name;     // the exported name ("default" for default export)
    bool   is_indirect;     // true for `export { x } from './other'`
    uint   req_module_idx;  // for indirect exports
    // True for a `let`, `const`, or `class` binding, which is subject to TDZ.
    // A `var` or `function` export is hoisted and initialized, so it never reads
    // as TDZ even before the exporting module's body runs. Indirect exports
    // leave this false, since the source module decides. Function declarations
    // are tracked in ModuleDef.func_decls and instantiated at link time.
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
    // True when every binding of the import statement was type-only and was
    // elided (see mark_type_only_req_modules). The statement is then gone
    // entirely: the target must not be evaluated as part of this module's
    // dependency order, or a cycle the erased types had broken would re-form.
    bool         type_only;
    // True when EVERY import of this specifier in the module is `import defer`
    // (ES2025 import-defer): the edge is skipped during the importer's
    // evaluation and the target runs on first string-keyed access to its
    // deferred namespace. One eager import anywhere in the module clears this,
    // per test262 module-imported-defer-and-eager: the module then evaluates
    // at the position where it is imported non-deferred. Layout mirrors
    // CompReqModuleEntry.
    bool         deferred;
    // Position in this module's evaluation order, normally the entry's own
    // index. A request first seen as `import defer` and later imported
    // eagerly takes the eager import's position instead, so the module
    // evaluates where it is imported non-deferred. Mirrors CompReqModuleEntry.
    uint         eval_order;
}

// ============================================================================
// ModuleHostHooks, the pluggable host callbacks
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
// ModuleDef, one module's definition
// ============================================================================

// `export * from` chains are walked recursively by
// collect_star_export_items_from; this bounds that recursion (a cycle the
// resolveSet guard does not catch, since each hop is a distinct module).
const uint MAX_STAR_EXPORTS = 16;

// A top-level `function` declaration in a module body. Recorded by the
// compiler during hoist_global_fn_decls so the linker can instantiate the
// closure once, during InitializeEnvironment (ECMA-262 16.2.1.5.5 step 17),
// rather than the body re-instantiating it on every evaluation.
struct FuncDeclEntry {
    char[] name;            // the declared function's binding name
    uint   inner_func_idx;  // index into mod.func.inner_funcs
}

struct ModuleDef {
    char[]                module_name;    // normalized path / identifier
    ModuleStatus          status;

    // Import/export metadata (populated during compilation). Growable: real
    // libraries run past a hundred import statements in one module
    // (fp-ts/ReadonlyArray.ts has 39 specifiers, fp-ts/index.ts 121), and a
    // fixed cap that silently dropped entries mis-linked the overflow onto
    // whatever module happened to hold index 0.
    List{ImportEntry}     imports;
    List{ExportEntry}     exports;
    List{StarExportEntry} star_exports;
    List{ReqModuleEntry}  req_modules;
    // Top-level function declarations, instantiated eagerly at link time.
    // Layout note: CompModuleDef mirrors every field up to here, so these
    // lists must appear in both structs at the same position.
    List{FuncDeclEntry}   func_decls;

    // Compiled bytecode for this module's body
    bytecode::CompiledFunction*   func;

    // Runtime environment holding this module's bindings
    env::EnvRecord*               env;

    // Module namespace object (lazily created for `import *`)
    HObject*                      namespace_obj;

    // Visit stamp for module_subgraph_is_async, compared against
    // module_defer_scan_epoch so a diamond is walked once per query.
    uint                          defer_scan_mark;

    // Deferred module namespace object (ES2025 import-defer), lazily created
    // for `import defer * as ns`. Distinct from namespace_obj: a module can be
    // imported both ways in one graph and the two objects are not the same
    // identity, though once evaluation is forced they expose the same exports.
    // Rooted for the ModuleDef's lifetime like namespace_obj.
    HObject*                      deferred_namespace_obj;

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

    // Persistent evaluation-completion promise (ECMA-262 [[CyclePromise]],
    // §16.2.1.5.2 Evaluate). Created lazily the first time evaluation starts
    // and settled exactly once when the module transitions to EVALUATED or
    // ERRORED, whether that transition happens synchronously (RET of a
    // non-async body, or the throw unwind) or later, asynchronously, via a
    // top-level-await body's own promise settling. Anything that needs to
    // observe "this module has finished evaluating" (dynamic import, a
    // parent module awaiting an async dependency) attaches a reaction here
    // instead of polling drain_microtasks. See promise_adopt_native.
    // Rooted with a ModuleDef-owned reference for the module's lifetime and
    // marked by mark_roots since ModuleDefs live outside the GC-scanned heap.
    HObject*                      eval_promise;

    // ECMA-262 [[CycleRoot]] (InnerModuleEvaluation step 16): the representative
    // of this module's strongly-connected component. Every member of an SCC --
    // not only the one that closed the cycle -- is stamped with the same root
    // by the stack-popping loop that ends the DFS, which is what lets a cycle
    // be treated as one unit: Evaluate() reads [[EvaluationError]] through the
    // root, so one member's failure is every member's failure. Null until that
    // loop runs.
    ModuleDef*                     cycle_root;

    // Tarjan bookkeeping for the SCC search ([[DFSIndex]]/[[DFSAncestorIndex]]).
    // dfs_index is discovery order; dfs_ancestor_index is the lowlink, the
    // smallest index reachable from this subtree through a back-edge. They are
    // equal exactly on the module that roots an SCC. `stack_prev` threads the
    // DFS stack intrusively, so the traversal needs no side allocation.
    uint                           dfs_index;
    uint                           dfs_ancestor_index;
    ModuleDef*                     stack_prev;
    bool                           on_stack;

    // ECMA-262 [[AsyncParentModules]]: reverse edges of the async dependency
    // graph -- the modules whose evaluation is blocked on this one. Both halves
    // of async settlement walk these: GatherAvailableAncestors to find whose
    // last dependency just landed, AsyncModuleExecutionRejected to push a
    // failure out to everyone transitively waiting. A forward-only search
    // cannot answer either question.
    ModuleDef**                    async_parents;
    uint                           async_parent_count;
    uint                           async_parent_cap;

    // ECMA-262 [[PendingAsyncDependencies]]: how many async dependencies have
    // yet to settle. The body runs when this reaches 0 -- a real count, so a
    // module with several async dependencies waits for all of them.
    uint                           pending_async_deps;

    // ECMA-262 [[AsyncEvaluationOrder]]: ~unset~ before the module is known to
    // be async, an integer once it is (assigned from a monotonic counter), and
    // ~done~ once it has finished. The integer is what orders the bodies that
    // become runnable together on one settlement, which is the whole reason
    // the field is observable: sibling importers of a shared async dependency
    // run in the order their DFS reached them, not in settlement order.
    AsyncEvalOrder                 async_eval_order;
    uint                           async_eval_index;

}

// ============================================================================
// Module cache on Heap
// ============================================================================

const uint INITIAL_MODULE_CAP = 16;

// Find a loaded module by normalized name. Returns null if not found.
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

// NodeNext twin probe: a `.js`/`.mjs`/`.cjs` specifier written in a TS
// source names the matching `.ts`/`.mts`/`.cts` file. Modern library
// sources (zod 3.25+, 4.x) are published that way. Returns a malloc'd twin
// path when that file exists, null when the specifier carries no JS
// extension or the twin is absent. The caller owns the returned buffer.
fn char[]? probe_ts_twin(char[] path) {
    usz base_len;
    String ext;
    if (path.len >= 3 && path[^3..] == ".js") {
        base_len = path.len - 3;
        ext = ".ts";
    } else if (path.len >= 4) {
        char[] t = path[^4..];
        if (t == ".mjs") {
            base_len = path.len - 4;
            ext = ".mts";
        } else if (t == ".cjs") {
            base_len = path.len - 4;
            ext = ".cts";
        } else {
            return MODULE_ERROR~;
        }
    } else {
        return MODULE_ERROR~;
    }
    usz total = base_len + ext.len;
    void* raw = alloc::malloc_try(mem, (sz)(total + 1)) ?? null;
    if (raw == null) {
        return MODULE_ERROR~;
    }
    mem::copy(raw, path.ptr, (sz)base_len);
    mem::copy((char*)raw + base_len, ext.ptr, (sz)ext.len);
    ((char*)raw)[total] = 0;
    char[] twin = ((char*)raw)[:total];
    if (try data = file::load(mem, (String)twin)) {
        mem::free(data.ptr);
        return twin;
    }
    mem::free(raw);
    return MODULE_ERROR~;
}

// Default source reader: read a module file from disk into a caller-owned
// buffer allocated from the engine's `mem` (libc-backed) heap. The returned
// slice is exactly the file's bytes; the lexer scans by length (no NUL
// sentinel required).
// Probes `normalized_name` as-is, then with module extensions appended, so
// a host resolve hook that returns a bare name still finds `./x.ts`
// (Node/Deno-style resolution).
fn char[]? default_module_read(char[] normalized_name, void* udata) {
    if (try data = file::load(mem, (String)normalized_name)) {
        if (data.len == 0) {
            mem::free(data.ptr);
            return MODULE_ERROR~;
        }
        return data;
    }
    // A `.js` specifier in a TS source names its `.ts` twin; read it when the
    // exact path is absent (NodeNext resolution, zod and friends).
    if (try twin_opt = probe_ts_twin(normalized_name)) {
        char[] twin = twin_opt;
        char[]? probe = file::load(mem, (String)twin);
        mem::free(twin);
        if (try loaded = probe) {
            if (loaded.len == 0) {
                mem::free(loaded.ptr);
                return MODULE_ERROR~;
            }
            return loaded;
        }
    }
    // Probe common extensions: `.ts`/`.mts`/`.cts` before `.js`/`.mjs`/`.cjs`
    // so a TS import `./x` finds `./x.ts` before a stale `./x.js`.
    String[6] exts = { ".ts", ".mts", ".cts", ".js", ".mjs", ".cjs" };
    for (usz e = 0; e < 6; e++) {
        String ext = exts[e];
        usz total = normalized_name.len + ext.len;
        void* raw = alloc::malloc_try(mem, (sz)(total + 1)) ?? null;
        if (raw == null) return MODULE_ERROR~;
        mem::copy(raw, normalized_name.ptr, (sz)(normalized_name.len));
        mem::copy((char*)raw + normalized_name.len, ext.ptr, (sz)(ext.len));
        ((char*)raw)[total] = 0;
        char[] candidate = ((char*)raw)[:total];
        char[]? probe = file::load(mem, (String)candidate);
        mem::free(raw);
        if (try loaded = probe) {
            if (loaded.len == 0) {
                mem::free(loaded.ptr);
                return MODULE_ERROR~;
            }
            return loaded;
        }
    }
    return MODULE_ERROR~;
}

// ============================================================================
// Module loader: resolve, load, compile, link, execute
// ============================================================================

// Call the host's resolve_name hook, or use the default.
// Return true if `name` already has a recognized module extension.
fn bool has_module_ext(char[] name) {
    if (name.len >= 3 && name[^3..] == ".ts") return true;
    if (name.len >= 3 && name[^3..] == ".js") return true;
    if (name.len >= 4) {
        char[] t = name[^4..];
        if (t == ".mts" || t == ".cts" || t == ".mjs" || t == ".cjs") return true;
    }
    return false;
}

// Try appending common extensions to `path` until one of the resulting
// files exists. Returns the full path (with extension) or the original if
// nothing matched. The returned buffer is heap-owned when different from
// input, otherwise input is returned as-is.
fn char[] resolve_extension(char[] path) {
    if (has_module_ext(path)) {
        // A missing exact file with a JS extension may name the TS twin of a
        // NodeNext-style source (`./x.js` in a .ts file means `./x.ts`).
        if (module_file_exists(path)) return path;
        char[]? twin = probe_ts_twin(path);
        if (try t = twin) return t;
        return path;
    }
    // Check if bare path exists.
    usz plen = path.len;
    void* pbuf = alloc::malloc_try(mem, (sz)(plen + 1)) ?? null;
    if (pbuf == null) return path;
    mem::copy(pbuf, path.ptr, (sz)(plen));
    ((char*)pbuf)[plen] = 0;
    char[] bare = ((char*)pbuf)[:plen];
    if (try bare_load = file::load(mem, (String)bare)) {
        mem::free(pbuf);
        mem::free(bare_load.ptr);
        return path;
    }
    mem::free(pbuf);

    String[6] exts = { ".ts", ".mts", ".cts", ".js", ".mjs", ".cjs" };
    for (usz e = 0; e < 6; e++) {
        String ext = exts[e];
        usz total = plen + ext.len;
        void* buf = alloc::malloc_try(mem, (sz)(total + 1)) ?? null;
        if (buf == null) return path;
        mem::copy(buf, path.ptr, (sz)(plen));
        mem::copy((char*)buf + plen, ext.ptr, (sz)(ext.len));
        ((char*)buf)[total] = 0;
        char[] candidate = ((char*)buf)[:total];
        if (try probe = file::load(mem, (String)candidate)) {
            mem::free(probe.ptr);
            return candidate;
        }
        mem::free(buf);
    }
    return path;
}

// True when a file exists at `path` (directories do not count: file::load
// on a directory fails or returns nothing usable, which reads as absent).
fn bool module_file_exists(char[] path) {
    if (try data = file::load(mem, (String)path)) {
        mem::free(data.ptr);
        return true;
    }
    return false;
}

// Resolve a bare package specifier by walking node_modules directories
// upward from the importing module's directory (the core of Node's
// resolution). For each ancestor directory D, D/node_modules/<name> is
// probed as: a subpath file when the specifier has one ('pkg/sub/mod'),
// else package.json's "main" entry, else an index file (extension probing
// applies, .ts before .js). No "exports" field support; vendored source
// trees do not use it. Returns null when nothing matched, so the caller
// falls back to plain extension probing of the specifier itself.
fn char[]? resolve_node_modules(char[] base_name, char[] specifier) {
    usz name_len = 0;
    while (name_len < specifier.len && specifier[name_len] != '/') name_len++;
    if (name_len == 0) return MODULE_ERROR~;
    // C3 slice ends are inclusive: [..name_len] would take name_len+1 bytes,
    // so a name running to the end of the specifier is the whole slice and a
    // bounded one ends at name_len-1.
    char[] pkg_name = name_len == specifier.len ? specifier : specifier[..name_len - 1];
    char[] sub = specifier[name_len..];  // "" or "/sub/path"

    // Ancestor walk starts at base_name's own directory. dir_end is the
    // length of the current directory prefix (one past its last '/');
    // 0 means the importer sits in the working directory.
    usz dir_end = 0;
    for (usz i = 0; i < base_name.len; i++) {
        if (base_name[i] == '/') dir_end = i + 1;
    }
    char[] nm = "node_modules/";
    for (;;) {
        usz plen = dir_end + nm.len + pkg_name.len;
        void* buf = alloc::malloc_try(mem, (sz)(plen + 1)) ?? null;
        if (buf == null) return MODULE_ERROR~;
        mem::copy(buf, base_name.ptr, (sz)(dir_end));
        mem::copy((char*)buf + dir_end, nm.ptr, (sz)(nm.len));
        mem::copy((char*)buf + dir_end + nm.len, pkg_name.ptr, (sz)(pkg_name.len));
        ((char*)buf)[plen] = 0;
        char[] pkg_dir = ((char*)buf)[:plen];

        bool resolved = false;
        char[] resolved_path = (char[])"";
        if (sub.len > 0) {
            // 'pkg/sub/path': address a file inside the package directly.
            // resolve_extension returns a NEW buffer on a hit and the input
            // unchanged on a miss; a specifier that already carries a module
            // extension comes back as-is without an existence check, so probe
            // that case explicitly.
            usz flen = plen + sub.len;
            void* fbuf = alloc::malloc_try(mem, (sz)(flen + 1)) ?? null;
            if (fbuf != null) {
                mem::copy(fbuf, pkg_dir.ptr, (sz)(plen));
                mem::copy((char*)fbuf + plen, sub.ptr, (sz)(sub.len));
                ((char*)fbuf)[flen] = 0;
                char[] full = ((char*)fbuf)[:flen];
                char[] r = resolve_extension(full);
                if (r.ptr != full.ptr || module_file_exists(r)) {
                    resolved_path = r;
                    resolved = true;
                } else {
                    mem::free(fbuf);
                }
            }
        } else {
            // Package root: package.json "main", then index.<ext>.
            usz pj_len = plen + 13;  // "/package.json"
            void* pjbuf = alloc::malloc_try(mem, (sz)(pj_len + 1)) ?? null;
            bool have_main = false;
            char[] main_path = (char[])"";
            if (pjbuf != null) {
                mem::copy(pjbuf, pkg_dir.ptr, (sz)(plen));
                char[] pj = "/package.json";
                mem::copy((char*)pjbuf + plen, pj.ptr, (sz)(pj.len));
                ((char*)pjbuf)[pj_len] = 0;
                char[] pj_path = ((char*)pjbuf)[:pj_len];
                if (try body = file::load(mem, (String)pj_path)) {
                    if (try m = package_json_main(body, pkg_dir)) {
                        main_path = m;
                        have_main = true;
                    }
                    mem::free(body.ptr);
                }
                mem::free(pjbuf);
            }
            if (have_main) {
                resolved_path = resolve_extension(main_path);
                resolved = true;
            } else {
                usz ilen = plen + 6;  // "/index"
                void* ibuf = alloc::malloc_try(mem, (sz)(ilen + 1)) ?? null;
                if (ibuf != null) {
                    mem::copy(ibuf, pkg_dir.ptr, (sz)(plen));
                    char[] idx = "/index";
                    mem::copy((char*)ibuf + plen, idx.ptr, (sz)(idx.len));
                    ((char*)ibuf)[ilen] = 0;
                    char[] index_path = ((char*)ibuf)[:ilen];
                    char[] r = resolve_extension(index_path);
                    if (r.ptr != index_path.ptr) {
                        resolved_path = r;
                        resolved = true;
                    } else {
                        mem::free(ibuf);
                    }
                }
            }
        }
        if (resolved) {
            mem::free(buf);
            return resolved_path;
        }
        mem::free(buf);

        // Walk up one directory: drop the last path segment of the prefix.
        if (dir_end == 0) return MODULE_ERROR~;
        usz prev = dir_end;
        dir_end = 0;
        for (usz i = 0; i + 1 < prev; i++) {
            if (base_name[i] == '/') dir_end = i + 1;
        }
        if (dir_end == prev) return MODULE_ERROR~;  // no progress (defensive)
    }
}

// Extract the "main" field from a package.json body and join it with the
// package directory, ready for extension probing. Returns null when the
// file has no "main" or the field is not a plain string.
fn char[]? package_json_main(char[] body, char[] pkg_dir) {
    char[] needle = "\"main\"";
    usz match = 0;
    usz i = 0;
    for (; i < body.len; i++) {
        if (body[i] == needle[match]) {
            match++;
            if (match == needle.len) { i++; break; }
        } else {
            match = (body[i] == needle[0]) ? 1 : 0;
        }
    }
    if (match != needle.len) return MODULE_ERROR~;
    // Skip whitespace, expect ':' then whitespace, then a quoted string.
    while (i < body.len && (body[i] == ' ' || body[i] == '\t')) i++;
    if (i >= body.len || body[i] != ':') return MODULE_ERROR~;
    i++;
    while (i < body.len && (body[i] == ' ' || body[i] == '\t')) i++;
    if (i >= body.len || body[i] != '"') return MODULE_ERROR~;
    i++;
    usz start = i;
    while (i < body.len && body[i] != '"') i++;
    if (i >= body.len) return MODULE_ERROR~;
    // Inclusive slice end: stop one before the closing quote.
    char[] main = body[start..i - 1];
    // Strip a leading "./" or "/" so dir + "/" + main concatenates cleanly.
    if (main.len >= 2 && main[0] == '.' && main[1] == '/') {
        main = main[2..];
    } else if (main.len >= 1 && main[0] == '/') {
        main = main[1..];
    }
    usz total = pkg_dir.len + 1 + main.len;
    void* raw = alloc::malloc_try(mem, (sz)(total + 1)) ?? null;
    if (raw == null) return MODULE_ERROR~;
    mem::copy(raw, pkg_dir.ptr, (sz)(pkg_dir.len));
    ((char*)raw)[pkg_dir.len] = '/';
    mem::copy((char*)raw + pkg_dir.len + 1, main.ptr, (sz)(main.len));
    ((char*)raw)[total] = 0;
    return ((char*)raw)[:total];
}

fn char[]? call_resolve_name(Heap* heap, char[] base_name, char[] specifier) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.resolve_name != null) {
            return hooks.resolve_name(base_name, specifier, hooks.udata);
        }
    }
    // A bare specifier names a package: resolve it through node_modules
    // directories first (Node-style), falling back to treating it as a
    // plain path (plus an extension probe so `import 'x'` can find `x.ts`).
    if (specifier.len > 0 && specifier[0] != '.') {
        char[]? pkg = resolve_node_modules(base_name, specifier);
        if (try pkg_path = pkg) return pkg;
        return resolve_extension(specifier);
    }
    // A relative specifier resolves against base_name's directory. A leading
    // "./" must be stripped in every case (not just when base_name itself
    // has a directory component) so the same file always normalizes to the
    // same identifier regardless of which importer's relative path reached
    // it, e.g. a top-level module loaded as "a.js" (no base directory) and
    // a same-directory sibling's "./a.js" re-export must resolve to the
    // identical cache key, or the module cache treats them as two distinct
    // ModuleDefs: a cyclic self-reference silently gets its own separate,
    // never-evaluated env, whose pre-linked TDZ export bindings then leak
    // into a module-namespace accessor read as a spurious TDZ throw.
    char[] rel = specifier;
    if (rel.len >= 2 && rel[0] == '.' && rel[1] == '/') {
        rel = rel[2..];
    }
    if (base_name.len == 0) return resolve_extension(rel);
    // Find last '/' in base_name to get directory
    int last_slash = -1;
    for (usz i = 0; i < base_name.len; i++) {
        if (base_name[i] == '/') last_slash = (int)i;
    }
    if (last_slash < 0) return resolve_extension(rel);
    char[] dir = base_name[:last_slash + 1];
    usz total = dir.len + rel.len;
    void* raw = alloc::malloc_try(mem, (sz)(total + 1)) ?? null;
    if (raw == null) return MODULE_ERROR~;
    mem::copy(raw, dir.ptr, (sz)(dir.len));
    mem::copy((char*)raw + dir.len, rel.ptr, (sz)(rel.len));
    ((char*)raw)[total] = 0;
    char[] joined = ((char*)raw)[:total];
    return resolve_extension(joined);
}

// Call the host's read_source hook, or use the default.
fn char[]? call_read_source(Heap* heap, char[] normalized_name) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.read_source != null) {
            return hooks.read_source(normalized_name, hooks.udata);
        }
    }
    return default_module_read(normalized_name, null);
}

// Call the host's on_module_loaded hook (if set).
fn void call_on_module_loaded(Heap* heap, void* mod) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.on_module_loaded != null) {
            (void)hooks.on_module_loaded(mod, hooks.udata);
        }
    }
}

// Call the host's on_module_evaluated hook (if set).
fn void call_on_module_evaluated(Heap* heap, void* mod) {
    if (heap.module_hooks != null) {
        ModuleHostHooks* hooks = (ModuleHostHooks*)heap.module_hooks;
        if (hooks.on_module_evaluated != null) {
            (void)hooks.on_module_evaluated(mod, hooks.udata);
        }
    }
}

// Find or create a ModuleDef by name in the heap's module cache.
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
    // The metadata lists grow on the malloc-backed default allocator (the one
    // the compiler uses for its own growable sets); ModuleDefs live until the
    // process exits, so the list storage is never freed.
    mod.imports.allocator = mem;
    mod.exports.allocator = mem;
    mod.star_exports.allocator = mem;
    mod.req_modules.allocator = mem;
    mod.func_decls.allocator = mem;

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

// Resolve a module specifier, compile it, and recursively resolve dependencies.
// `wants_json` selects the JSON-module load path (parse the file with
// JSON.parse; sole export is `default`) rather than ECMAScript compilation.
//
// `quiet` suppresses the compile-error diagnostic on stderr, for a caller that
// turns the failure into a value the program can observe: a dynamic import()
// rejects its promise with the parked SyntaxError, and printing as well emits
// an engine diagnostic for an error the script is handling. The static path
// leaves it false — there the diagnostic is the only report of what went wrong.
fn ModuleDef*? resolve_module(Heap* heap, char[] specifier, char[] base_name, bool wants_json = false, bool quiet = false) {
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
        ExportEntry def;
        def.local_name = "default";
        def.export_name = "default";
        def.is_indirect = false;
        def.req_module_idx = 0;
        def.is_lexical = false;
        mod.exports.push(def);
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
    Lexer lex = lexer::lexer_init(source, heap, normalized);
    defer lex.free_arena();
    // ES2024 §12.5: the HTML-like comment grammar is reachable from Script
    // only, so in a Module `<!--` and `-->` stay real tokens and the source is
    // a SyntaxError.
    lex.html_comments = false;
    lex.skip_hashbang();
    // TypeScript mode when the module specifier ends in `.ts`/`.mts`/`.cts`.
    if (normalized.len >= 3) {
        char[] tail3 = normalized[^3..];
        if (tail3[0] == '.' && tail3[1] == 't' && tail3[2] == 's') {
            lex.ts_mode = true;
        } else if (normalized.len >= 4) {
            char[] tail4 = normalized[^4..];
            if (tail4[0] == '.' &&
                (tail4[1] == 'm' || tail4[1] == 'c') &&
                tail4[2] == 't' && tail4[3] == 's') {
                lex.ts_mode = true;
            }
        }
    }
    bytecode::CompiledFunction*? func_opt = compiler::compile_module(&lex, heap, normalized, mod);
    if (catch err = func_opt) {
        char* msg  = &lex.err_msg[0];
        uint  line = lex.err_line;
        uint  col  = lex.err_col;
        usz   msg_len = (usz)((ZString)msg).len();
        // Build the module name portion into a temp buffer for printing.
        char[512] name_buf;
        usz name_copy = normalized.len < 511 ? normalized.len : 511;
        mem::copy(&name_buf[0], normalized.ptr, (sz)(name_copy));
        name_buf[name_copy] = 0;
        if (!quiet) {
            // Name the error type, matching the script path in cli/boomkat.c3
            // and the SyntaxError parked on the heap channel just below. A
            // module parse failure IS a SyntaxError; printing a bare "compile
            // error" left the type unrecoverable for anything reading stderr.
            if (msg_len > 0) {
                io::eprintfn("%s: SyntaxError at line %d:%d: %s",
                             (ZString)name_buf[0..], line, col, (ZString)msg);
            } else {
                io::eprintfn("%s: SyntaxError at line %d:%d",
                             (ZString)name_buf[0..], line, col);
            }
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
    // The normalized module name rides the lexer into finish(), which copies it
    // onto the compiled-function tree (body + every nested function template).
    // `import.meta` resolves its owning module from the currently executing
    // function's filename, so nested functions must carry it too
    // (GetActiveScriptOrModule / §13.3.12 must observe the DEFINING module, not
    // the one whose body happens to be running).

    // 6. Notify host
    call_on_module_loaded(heap, mod);

    // 7. Recursively resolve dependencies
    for (uint i = 0; i < (uint)mod.req_modules.len(); i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        // A dependency of a quietly-resolved module is quiet too: its parse
        // failure reaches the same promise rejection.
        ModuleDef*? dep = resolve_module(heap, rme.module_name, normalized, rme.wants_json, quiet);
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

// ResolveExport(exportName, resolveSet). ECMA-262 16.2.1.6.3 for a
// SourceTextModuleRecord. Returns a resolution binding, or NULL/AMBIGUOUS.
// `set`/`set_len` carry the resolveSet across the recursion to break circular
// import requests (step 2: if the same {module, exportName} is already in the
// set, this is a circular request → NULL).
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
    for (uint i = 0; i < (uint)mod.exports.len(); i++) {
        ExportEntry* ee = &mod.exports[i];
        if (ee.is_indirect) continue;
        if (char_slice_eq(ee.export_name, export_name)) {
            return { ResolveExportKind.RESOLVED, mod, ee.local_name };
        }
    }

    // Step 5: indirect exports (`export { x } from './other'`). Delegate to the
    // imported module's ResolveExport for the re-exported name.
    for (uint i = 0; i < (uint)mod.exports.len(); i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect) continue;
        if (!char_slice_eq(ee.export_name, export_name)) continue;
        if (ee.req_module_idx >= (uint)mod.req_modules.len()) return { ResolveExportKind.NULL, null, {} };
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
    for (uint i = 0; i < (uint)mod.star_exports.len(); i++) {
        StarExportEntry* se = &mod.star_exports[i];
        if (se.req_module_idx >= (uint)mod.req_modules.len()) continue;
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

// Park a link-phase static-semantics SyntaxError on the heap error channel and
// return false, for use as a `return` in the link-time validators.
fn bool module_raise_link_error(Heap* heap, char[] msg) {
    TVal se = module_syntax_error(heap, msg);
    heap.error_value.set_undefined();
    heap.tval_copy_ref(&heap.error_value, &se);
    heap.has_error = true;
    return false;
}

// Validate a module's indirect exports (ECMA-262 16.2.1.6.2
// InitializeEnvironment step 4): each `export { x } from './y'` must resolve to
// exactly one binding. A NULL or AMBIGUOUS resolution is a SyntaxError. On
// failure parks a SyntaxError on the heap error channel and returns false.
fn bool validate_indirect_exports(Heap* heap, ModuleDef* mod) {
    for (uint i = 0; i < (uint)mod.exports.len(); i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect) continue;
        ResolveSetEntry[RESOLVE_SET_MAX] set;
        ResolveExportResult r = resolve_export(mod, ee.export_name, &set[0], 0);
        if (r.kind != ResolveExportKind.RESOLVED) {
            char[256] buf;
            char[] prefix = "re-exported name '";
            char[] suffix = "' does not resolve to a single binding";
            usz nlen = ee.export_name.len < 200 ? ee.export_name.len : 200;
            usz off = 0;
            mem::copy(&buf[0], prefix.ptr, (sz)prefix.len);
            off += prefix.len;
            mem::copy((char*)&buf[0] + off, ee.export_name.ptr, (sz)nlen);
            off += nlen;
            mem::copy((char*)&buf[0] + off, suffix.ptr, (sz)suffix.len);
            off += suffix.len;
            buf[off] = 0;
            return module_raise_link_error(heap, ((char*)&buf[0])[:off]);
        }
    }
    return true;
}

// True when the module's normalized name carries a TypeScript extension
// (.ts/.mts/.cts), i.e. it was compiled in ts_mode.
fn bool module_is_ts(ModuleDef* mod) {
    char[] n = mod.module_name;
    if (n.len >= 3) {
        char[] t = n[^3..];
        if (t[0] == '.' && t[1] == 't' && t[2] == 's') return true;
        if (n.len >= 4) {
            char[] t4 = n[^4..];
            if (t4[0] == '.' && (t4[1] == 'm' || t4[1] == 'c') && t4[2] == 't' && t4[3] == 's') return true;
        }
    }
    return false;
}

// A TS module's `import { X } from './y'` where X is only a type (the
// stripper erased it from y) is elided per binding in the import-install
// loop. When EVERY binding of one import statement is type-only, the
// statement is gone entirely: y must not be pulled into this module's
// dependency order, or evaluating y first would re-form a cycle the erased
// types had broken and trip TDZ on a const the other module reads.
fn void mark_type_only_req_modules(ModuleDef* mod) {
    if (!module_is_ts(mod)) return;
    for (uint ri = 0; ri < (uint)mod.req_modules.len(); ri++) {
        ReqModuleEntry* rme = &mod.req_modules[ri];
        if (rme.resolved == null) continue;
        uint total = 0;
        uint elided = 0;
        for (uint i = 0; i < (uint)mod.imports.len(); i++) {
            ImportEntry* ie = &mod.imports[i];
            if (ie.req_module_idx != ri) continue;
            total++;
            if (ie.is_star) continue;  // a namespace binding never elides
            ResolveSetEntry[RESOLVE_SET_MAX] set;
            ResolveExportResult r = resolve_export((ModuleDef*)rme.resolved, ie.import_name, &set[0], 0);
            if (r.kind != ResolveExportKind.RESOLVED) elided++;
        }
        if (total > 0 && elided == total) rme.type_only = true;
    }
}

// Validate a module's named imports (ECMA-262 16.2.1.6.2 InitializeEnvironment
// step 7.a-b): for each `import { x } from './y'`, ResolveExport(x) on the
// requested module must yield exactly one binding. A NULL (absent name, or a
// circular request the resolveSet cut) or AMBIGUOUS (conflicting `export *`
// stars) resolution is an early SyntaxError, raised HERE at link time so that
// no module body has run yet — matching node, which reports "does not provide
// an export named 'x'" before any top-level statement of the importer
// executes.
//
// `import * as ns` is exempt: a namespace object is always constructible and
// a missing member reads back as plain `undefined` (§10.4.6.7), which is not
// an error. `import 'x'` for side effects declares no binding at all.
//
// A JSON module exports only `default`; any other named import from one is the
// same resolution-phase SyntaxError (JSON modules define no named bindings) and
// is checked here rather than against resolve_export, which has no export
// entries to walk for a bodyless JSON module.
fn bool validate_imports(Heap* heap, ModuleDef* mod) {
    for (uint i = 0; i < (uint)mod.imports.len(); i++) {
        ImportEntry* ie = &mod.imports[i];
        if (ie.is_star) continue;
        if (ie.req_module_idx >= (uint)mod.req_modules.len()) continue;
        ReqModuleEntry* rme = &mod.req_modules[ie.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* source_mod = (ModuleDef*)rme.resolved;
        if (source_mod.is_json) {
            if (!char_slice_eq(ie.import_name, "default")) {
                return module_raise_link_error(heap,
                    "requested JSON module does not provide the requested export");
            }
            continue;
        }
        ResolveSetEntry[RESOLVE_SET_MAX] set;
        ResolveExportResult r = resolve_export(source_mod, ie.import_name, &set[0], 0);
        if (r.kind != ResolveExportKind.RESOLVED) {
            // A TS module's type-only named imports (`import { Interface } from
            // './x'` without a `type` modifier) name exports the stripper
            // erased from the target; without cross-module type info the
            // elision can only be decided here. Only .ts importers get it: a
            // plain JS module importing a missing name is still the spec's
            // link-time SyntaxError.
            if (module_is_ts(mod)) continue;
            char[256] nbuf;
            char[] nprefix = "module does not provide an export named '";
            char[] nsuffix = "'";
            usz nnlen = ie.import_name.len < 200 ? ie.import_name.len : 200;
            usz noff = 0;
            mem::copy(&nbuf[0], nprefix.ptr, (sz)nprefix.len);
            noff += nprefix.len;
            mem::copy((char*)&nbuf[0] + noff, ie.import_name.ptr, (sz)nnlen);
            noff += nnlen;
            mem::copy((char*)&nbuf[0] + noff, nsuffix.ptr, (sz)nsuffix.len);
            noff += nsuffix.len;
            nbuf[noff] = 0;
            return module_raise_link_error(heap, ((char*)&nbuf[0])[:noff]);
        }
    }
    return true;
}

// Link a module: resolve import bindings from source modules' envs.
// Phase 1 (initial): import bindings are copied at link time.
fn bool link_module(Heap* heap, vm::Vm* vm, ModuleDef* mod, EnvRecord* global_env) {
    if (mod.status == ModuleStatus.LINKED || mod.status == ModuleStatus.EVALUATED) return true;
    // LINKING means we're already linking this module further up the call
    // stack, so this is a dependency cycle, possibly a self-import. Treat it as
    // done to break the recursion; its env exists and bindings resolve once the
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
    // modules define no named bindings. ECMA-262; `import {x}` must be a
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
    // env (imported bindings, and, below, eagerly instantiated exported
    // function closures) survive collection between link and evaluation.
    // execute_module only roots the env in the path where it creates the env
    // itself; when link_module creates it first (the normal path), that block
    // is skipped, so root it here.
    if (mod.env.bindings != null) {
        heap.register_gc_root(mod.env.bindings.as_header());
    }

    // Link dependencies first with the same parent env.
    for (uint i = 0; i < (uint)mod.req_modules.len(); i++) {
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

    // Validate every named import resolves (16.2.1.6.2 step 7.a-b). This must
    // happen at LINK time, before any module body runs: an import of a name the
    // target does not export is an early SyntaxError, not an undefined binding.
    // Only VALIDATION happens here. The actual bindings (including this
    // module's own self-imports) are installed later by execute_module's
    // live-binding loop, which runs after every module env's export/TDZ
    // pre-declaration (below) has completed; installing them before that
    // pre-declaration would shadow a self-imported `let`/`const`/`class`
    // export's TDZ sentinel with a premature `undefined` copy.
    if (!validate_imports(heap, mod)) return false;
    mark_type_only_req_modules(mod);

    // NOTE: an indirect export (`export { x } from './other'`) installs NO
    // binding in mod.env at link time either. See the matching note in
    // execute_module for why a re-exported name must never become a
    // resolvable identifier inside the re-exporting module's own body.

    // Instantiate top-level `function` declarations (ECMA-262 16.2.1.5.5
    // step 17). InitializeEnvironment creates each function's closure once,
    // during linking, before ANY module body runs. This is what makes a
    // cyclic early import observe the hoisted function (not undefined) AND
    // keeps the binding's identity stable: the module body no longer emits
    // CLOSURE+DECLVAR for these (see hoist_global_fn_decls). The closure
    // captures the module env as both var and lex environment (its top-level
    // enclosing scope), exactly as the CLOSURE opcode would.
    if (mod.func != null) {
        for (uint i = 0; i < (uint)mod.func_decls.len(); i++) {
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
    // a cyclically-importing module can observe this env slot beforehand, it
    // must see the sentinel, not undefined, so builtin_module_binding_getter
    // (builtins/core.c3) throws instead of yielding a stale undefined.
    // Function-declaration exports are already bound above and are skipped by
    // the env_has check.
    for (uint i = 0; i < (uint)mod.exports.len(); i++) {
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

// Record a module's evaluation error and mark it ERRORED. The thrown value is
// captured out of the heap error channel with a ModuleDef-owned reference so it
// survives GC and can re-reject every later Evaluate() of the same module.
// Leaves the error channel populated (the caller still surfaces the throw for
// the current evaluation). Always returns false for use in `return`.
fn bool module_record_eval_error(Heap* heap, Vm* vm, ModuleDef* mod) {
    mod.status = ModuleStatus.ERRORED;
    if (!mod.has_eval_error) {
        mod.eval_error.set_undefined();
        if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
            heap.tval_copy_ref(&mod.eval_error, &heap.error_value);
        }
        mod.has_eval_error = true;
    }
    module_settle_eval_promise(heap, vm, mod, false);
    return false;
}

// Get (creating on first use) the module's persistent evaluation-completion
// promise. ECMA-262 [[CyclePromise]]. Returns null only on allocation
// failure, in which case a waiter falls back to treating the module as
// already-settled the next time it observes mod.status directly.
fn HObject* module_ensure_eval_promise(Heap* heap, ModuleDef* mod) {
    if (mod.eval_promise != null) return mod.eval_promise;
    HObject*? prom_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return null;
    HObject* prom = prom_raw;
    prom.prototype = heap.promise_proto;
    builtins::promise_init(prom);
    prom.as_header().incref();  // ModuleDef-owned reference, held for its lifetime
    mod.eval_promise = prom;
    return prom;
}

// Settle the module's persistent evaluation-completion promise (once, a
// no-op if already settled or if evaluation never allocated one, e.g. a
// JSON module or a plain synchronous body nobody awaited).
//
// `ok` selects fulfillment or rejection (with mod.eval_error /
// heap.error_value). Unlike the spec's [[CyclePromise]] (which always
// fulfills with undefined), this internal promise fulfills with the
// module's NAMESPACE OBJECT: it exists purely so a dynamic import() of an
// async or TLA module, which §16.2.1.5.2 and §13.3.10 require to resolve with that
// namespace object, can attach a single reaction here instead of building
// the namespace separately after polling for completion. No other caller
// observes eval_promise, so this deviation from [[CyclePromise]]'s literal
// completion value is not spec-observable.
fn void module_settle_eval_promise(Heap* heap, Vm* vm, ModuleDef* mod, bool ok) {
    if (mod.eval_promise == null) return;
    if (builtins::promise_get_state(mod.eval_promise, builtins::PROMISE_PENDING)
        != builtins::PROMISE_PENDING) return;
    TVal val;
    if (ok) {
        HObject*? ns_opt = build_namespace_object(heap, mod);
        if (try ns = ns_opt) {
            val.set_object(ns);
        } else {
            val = module_type_error(heap, "cannot build module namespace object");
        }
        builtins::promise_settle(mod.eval_promise, builtins::PROMISE_FULFILLED, &val, heap);
    } else {
        val.set_undefined();
        if (mod.has_eval_error) {
            val = mod.eval_error;
        } else if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
            val = heap.error_value;
        }
        builtins::promise_settle(mod.eval_promise, builtins::PROMISE_REJECTED, &val, heap);
    }
    builtins::promise_trigger_reactions(mod.eval_promise, heap, (void*)vm);
}

// Hidden property key carrying a MODULE_PENDING_FINISH reaction's target
// module name as an interned string rather than a raw ModuleDef*, so the
// reaction is a plain JS-visible-shaped object needing no new native-pointer
// storage; heap_find_loaded_module recovers `mod` from it when the reaction
// fires.
const char[] MODULE_SETTLEMENT_NAME_KEY = "\xFFmpf_name";

// Attach a reaction to `pending` (the per-call promise execute_module_async
// or execute_module_nested handed back for a still-suspended async/TLA
// body) that finalizes `mod` once it settles: transitions mod.status to
// EVALUATED or ERRORED and settles mod.eval_promise with the real
// namespace object or rejection reason. Until this fires, mod stays
// EVALUATING_ASYNC and mod.eval_promise stays pending, so anything that already chained onto mod.eval_promise (a
// dynamic import job, a sibling static import) observes the correct
// settlement once it happens rather than the suspended activation's own
// raw (always-undefined) completion value.
//
// The onFulfilled/onRejected handlers are real FUNCTION objects (not
// lightfuncs) carrying mod's name as a hidden prop: promise_trigger_reactions
// invokes a reaction's handler directly as the queued microtask job (with
// the settled value as its sole argument, not the reaction object itself),
// so per-instance data must live on the handler object, recovered via
// ctx.callee_obj, which is the pattern builtin_dynamic_import_job uses.
// Route `source`'s settlement into the async module handlers, so a suspended
// body finishes through exactly the same path a dependency's settlement takes.
fn void module_attach_async_settlement(Heap* heap, ModuleDef* mod, HObject* source) {
    module_attach_named_reaction(heap, mod, source,
        Builtin.MODULE_SETTLED_FULFILLED.ordinal, Builtin.MODULE_SETTLED_REJECTED.ordinal);
}


// Build onFulfilled/onRejected handler FUNCTION objects for the given builtin
// ordinals and attach them to `source`. Each carries mod's name as a hidden
// property, since a builtin reaction has no capture to hold the module in.
fn void module_attach_named_reaction(Heap* heap, ModuleDef* mod, HObject* source,
                                      uint onf_ordinal, uint onr_ordinal) {
    HString* name_key = heap.str_intern(MODULE_SETTLEMENT_NAME_KEY);
    HString* name_str = heap.str_intern(mod.module_name);
    HString* onf_key = heap.str_intern("onFulfilled");
    HString* onr_key = heap.str_intern("onRejected");
    if (name_key == null || name_str == null || onf_key == null || onr_key == null) return;
    TVal name_tv; name_tv.set_string(name_str);

    HObject*? onf_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = onf_raw) return;
    HObject* onf = onf_raw;
    onf.flags.callable = true;
    onf.prototype = heap.function_proto;
    (*onf.extra_ptr()).func.builtin_fn_index = (int)onf_ordinal;
    onf.put_prop(name_key, name_tv, hobject::PROP_FLAGS_WEC, heap);

    HObject*? onr_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = onr_raw) return;
    HObject* onr = onr_raw;
    onr.flags.callable = true;
    onr.prototype = heap.function_proto;
    (*onr.extra_ptr()).func.builtin_fn_index = (int)onr_ordinal;
    onr.put_prop(name_key, name_tv, hobject::PROP_FLAGS_WEC, heap);

    HObject*? rxn_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = rxn_raw) return;
    HObject* rxn = rxn_raw;
    rxn.prototype = heap.object_proto;
    TVal onf_tv; onf_tv.set_object(onf);
    TVal onr_tv; onr_tv.set_object(onr);
    rxn.put_prop(onf_key, onf_tv, hobject::PROP_FLAGS_WEC, heap);
    rxn.put_prop(onr_key, onr_tv, hobject::PROP_FLAGS_WEC, heap);
    // No `downstream`: these handlers act purely for their side effect
    // (finalizing mod, or running its deferred continuation) and their
    // return value is discarded, leaving `downstream` undefined means
    // promise_microtask_after's downstream check is a no-op.

    uint state = builtins::promise_get_state(source, builtins::PROMISE_PENDING);
    builtins::promise_add_reaction(source, rxn, heap);
    if (state != builtins::PROMISE_PENDING) {
        builtins::promise_trigger_reactions(source, heap, null);
    }
}

// The module a settlement reaction belongs to, recovered from the name the
// handler object carries. Reactions are plain builtin closures, so the module
// identity has to travel on the object rather than in a capture.
fn ModuleDef* module_of_reaction(BuiltinContext* ctx) {
    if (ctx.callee_obj == null) return null;
    HString* name_key = ctx.heap.str_intern(MODULE_SETTLEMENT_NAME_KEY);
    if (name_key == null) return null;
    char[] name = {};
    if (try nv = ctx.callee_obj.get_prop(name_key, ctx.heap)) {
        if (nv.is_string()) name = ((HString*)nv.get_heapptr()).get_data();
    }
    if (name.len == 0) return null;
    return heap_find_loaded_module(ctx.heap, name);
}

// PromiseReactionJob onFulfilled for an async module body: the body ran to
// completion, so hand it to AsyncModuleExecutionFulfilled, which finalizes it
// and runs whatever ancestors that unblocked.
fn void builtin_module_settled_fulfilled(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    ModuleDef* mod = module_of_reaction(ctx);
    if (mod == null) return;
    module_async_execution_fulfilled(ctx.heap, (Vm*)ctx.vm, mod);
}

// PromiseReactionJob onRejected for an async module body. The rejection reason
// is this handler's sole argument (§27.2.2.1) and becomes the evaluation error
// for the module AND for everything transitively waiting on it.
fn void builtin_module_settled_rejected(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    ModuleDef* mod = module_of_reaction(ctx);
    if (mod == null) return;
    TVal reason; reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];
    module_async_execution_rejected(ctx.heap, (Vm*)ctx.vm, mod, &reason);
}

// ============================================================================
// Async module evaluation (ECMA-262 §16.2.1.6.1.3.x)
// ============================================================================
//
// A module with top-level await, or one that depends on such a module, cannot
// finish inside the depth-first traversal that starts it: its body suspends,
// or it has nothing to run until its dependencies land. The spec handles this
// without ever blocking the traversal, using three pieces of state that this
// section maintains together:
//
//   pending_async_deps  how many async dependencies are still outstanding.
//                       Reaching 0 is what makes a body runnable.
//   async_parents       reverse edges. When a module settles, this is how it
//                       finds who was waiting on it -- forward edges cannot
//                       answer that question.
//   async_eval_index    a monotonic ticket taken when a module is first known
//                       to be async. Several bodies can become runnable on one
//                       settlement; they run in ticket order, which is DFS
//                       discovery order, not settlement order.
//
// The observable consequence is that sibling importers of one shared async
// dependency run in the order the traversal reached them. See
// language/module-code/top-level-await/dfs-invariant.js.

// The agent-wide [[ModuleAsyncEvaluationCount]]. Handed out in ascending order
// and, as the spec permits, reset once no module is holding a ticket -- which
// keeps the counter from growing without bound across many evaluations.
uint module_async_eval_counter = 0;
uint module_async_eval_outstanding = 0;

// Non-zero while a batch of newly-runnable bodies is being executed. A
// synchronous body finishing inside the batch was already accounted for by the
// gather that built it, so it must settle without starting a batch of its own --
// otherwise its ancestors would run ahead of its not-yet-reached siblings.
uint module_batch_depth = 0;
ModuleDef** module_batch_list = null;
uint module_batch_count = 0;
uint module_batch_cursor = 0;
uint module_batch_cap = 0;

// Append `mod` to the batch currently being assembled, growing it as needed.
// Returns false only on allocation failure, where dropping the module is the
// least-bad option: it stays pending rather than running out of order.
fn bool module_batch_push(Heap* heap, ModuleDef* mod) {
    if (module_batch_count == module_batch_cap) {
        uint new_cap = module_batch_cap == 0 ? 8 : module_batch_cap * 2;
        void* grown = heap.realloc_func(heap.heap_udata, (void*)module_batch_list,
                                        (usz)new_cap * void*::size);
        if (grown == null) return false;
        module_batch_list = (ModuleDef**)grown;
        module_batch_cap = new_cap;
    }
    module_batch_list[module_batch_count] = mod;
    module_batch_count++;
    return true;
}

// Release the side allocations a ModuleDef owns. Called just before the record
// itself is freed; `raw` is the ModuleDef as the cache stores it.
fn void module_release_buffers(Heap* heap, void* raw) {
    if (raw == null) return;
    ModuleDef* mod = (ModuleDef*)raw;
    if (mod.async_parents != null) {
        heap.free_func(heap.heap_udata, (void*)mod.async_parents);
        mod.async_parents = null;
        mod.async_parent_count = 0;
        mod.async_parent_cap = 0;
    }
}

// Release the shared batch buffer. It is reused across evaluations, so it is
// freed with the module cache rather than after each batch.
fn void module_release_batch_buffer(Heap* heap) {
    if (module_batch_list != null) {
        heap.free_func(heap.heap_udata, (void*)module_batch_list);
        module_batch_list = null;
    }
    module_batch_count = 0;
    module_batch_cursor = 0;
    module_batch_cap = 0;
}

// ECMA-262 IncrementModuleAsyncEvaluationCount: give `mod` its place in the
// async ordering. Idempotent, so a module that becomes async through several
// dependencies still holds exactly one ticket.
fn void module_take_async_order(ModuleDef* mod) {
    if (mod.async_eval_order != AsyncEvalOrder.UNSET) return;
    mod.async_eval_order = AsyncEvalOrder.ORDERED;
    mod.async_eval_index = module_async_eval_counter;
    module_async_eval_counter++;
    module_async_eval_outstanding++;
}

// Retire `mod`'s ticket. Once none are outstanding the counter is unobservable,
// so it rewinds to 0.
fn void module_release_async_order(ModuleDef* mod) {
    if (mod.async_eval_order != AsyncEvalOrder.ORDERED) return;
    mod.async_eval_order = AsyncEvalOrder.DONE;
    if (module_async_eval_outstanding > 0) module_async_eval_outstanding--;
    if (module_async_eval_outstanding == 0) module_async_eval_counter = 0;
}

// The SCC representative whose evaluation state speaks for `mod` (Evaluate
// step 3.a). A module in a cycle defers to its root; one that is not in a
// cycle, or has not finished its traversal yet, speaks for itself.
fn ModuleDef* module_cycle_root(ModuleDef* mod) {
    if (mod == null) return null;
    return mod.cycle_root != null ? mod.cycle_root : mod;
}

// True once `mod` has an outcome to report -- either it finished, or the
// component it belongs to failed.
fn bool module_is_settled(ModuleDef* mod) {
    if (mod == null) return false;
    if (mod.status == ModuleStatus.EVALUATED || mod.status == ModuleStatus.ERRORED) return true;
    return module_cycle_root(mod).status == ModuleStatus.ERRORED;
}

// Record `parent` as blocked on `mod` ([[AsyncParentModules]]). Duplicates are
// ignored: a diamond where one parent imports the same async module twice must
// still decrement its pending count exactly once per distinct edge.
fn bool module_add_async_parent(Heap* heap, ModuleDef* mod, ModuleDef* parent) {
    if (mod == null || parent == null || mod == parent) return false;
    for (uint i = 0; i < mod.async_parent_count; i++) {
        if (mod.async_parents[i] == parent) return false;
    }
    if (mod.async_parent_count == mod.async_parent_cap) {
        uint new_cap = mod.async_parent_cap == 0 ? 4 : mod.async_parent_cap * 2;
        void* grown = heap.realloc_func(heap.heap_udata, (void*)mod.async_parents,
                                        (usz)new_cap * void*::size);
        if (grown == null) return false;
        mod.async_parents = (ModuleDef**)grown;
        mod.async_parent_cap = new_cap;
    }
    mod.async_parents[mod.async_parent_count] = parent;
    mod.async_parent_count++;
    return true;
}

// ECMA-262 GatherAvailableAncestors: `mod` has just finished, so every parent
// waiting on it loses one outstanding dependency. Those that reach zero are
// collected into `list` -- they are now runnable. A non-TLA parent that becomes
// runnable is itself about to run synchronously, so recursion continues
// through it to find what its completion in turn unblocks.
fn void module_gather_available_ancestors(Heap* heap, ModuleDef* mod) {
    for (uint i = 0; i < mod.async_parent_count; i++) {
        ModuleDef* parent = mod.async_parents[i];
        if (parent == null) continue;
        // A parent whose component already failed is not runnable; the failure
        // path settles it instead.
        if (module_cycle_root(parent).status == ModuleStatus.ERRORED) continue;
        bool seen = false;
        for (uint j = 0; j < module_batch_count; j++) {
            if (module_batch_list[j] == parent) { seen = true; break; }
        }
        if (seen) continue;
        if (parent.pending_async_deps > 0) parent.pending_async_deps--;
        if (parent.pending_async_deps != 0) continue;
        if (!module_batch_push(heap, parent)) continue;
        // A parent with its own top-level await will re-suspend when it runs,
        // so its completion is a separate future event; only a synchronous
        // parent's completion is already implied by this batch.
        if (parent.func == null || !parent.func.has_tla()) {
            module_gather_available_ancestors(heap, parent);
        }
    }
}

// Sort `list` by async_eval_index ascending -- the order the DFS discovered
// these modules, which is the order their bodies must run in. Insertion sort:
// the list is a handful of entries at most, and it is stable.
fn void module_sort_exec_list(ModuleDef** list, uint count) {
    for (uint i = 1; i < count; i++) {
        ModuleDef* cur = list[i];
        uint j = i;
        while (j > 0 && list[j - 1].async_eval_index > cur.async_eval_index) {
            list[j] = list[j - 1];
            j--;
        }
        list[j] = cur;
    }
}

// ECMA-262 AsyncModuleExecutionFulfilled: `mod`'s body has finished. Mark it
// evaluated, settle whatever is waiting on it, then run every ancestor this
// unblocked -- in async_eval_index order, which is what makes sibling
// importers of a shared async dependency observe DFS order rather than
// settlement order.
fn void module_async_execution_fulfilled(Heap* heap, Vm* vm, ModuleDef* mod) {
    if (mod.status == ModuleStatus.EVALUATED || mod.status == ModuleStatus.ERRORED) return;
    module_finish_evaluated(heap, vm, mod);

    // Everything this completion unblocks runs as ONE batch, in ticket order.
    // A nested completion -- a synchronous ancestor finishing inside the batch
    // below -- appends into the SAME list, which the loop is still walking, so
    // its own unblocked ancestors get sorted in among the entries not yet
    // reached instead of cutting ahead of them.
    if (module_batch_depth > 0) {
        module_gather_available_ancestors(heap, mod);
        module_sort_exec_list(module_batch_list + module_batch_cursor,
                              module_batch_count - module_batch_cursor);
        return;
    }

    module_batch_count = 0;
    module_batch_cursor = 0;
    module_gather_available_ancestors(heap, mod);
    module_sort_exec_list(module_batch_list, module_batch_count);

    module_batch_depth++;
    defer module_batch_depth--;
    while (module_batch_cursor < module_batch_count) {
        ModuleDef* ancestor = module_batch_list[module_batch_cursor];
        module_batch_cursor++;
        if (ancestor.status == ModuleStatus.EVALUATED ||
            ancestor.status == ModuleStatus.ERRORED) continue;
        // A TLA ancestor re-suspends and reports separately; a synchronous one
        // finishes inline and folds its own unblocked ancestors into this list.
        // Go through module_execute_continue, not module_run_body: this is the
        // ancestor's FIRST chance to run, so its import bindings still have to
        // be installed against the dependencies that just finished.
        (void)module_execute_continue(heap, vm, ancestor);
    }
}

// Mark `mod` finished and settle everything waiting on it.
fn void module_finish_evaluated(Heap* heap, Vm* vm, ModuleDef* mod) {
    module_release_async_order(mod);
    mod.status = ModuleStatus.EVALUATED;
    module_settle_eval_promise(heap, vm, mod, true);
    call_on_module_evaluated(heap, mod);
}

// ECMA-262 AsyncModuleExecutionRejected: `mod` failed. Cache the error, settle
// its waiters, and push the SAME error value out along the reverse edges so
// every module transitively blocked on it reports the identical failure --
// which is what a later import of any of them must re-reject with.
fn void module_async_execution_rejected(Heap* heap, Vm* vm, ModuleDef* mod, TVal* error) {
    if (mod.status == ModuleStatus.EVALUATED || mod.status == ModuleStatus.ERRORED) return;

    module_release_async_order(mod);
    mod.status = ModuleStatus.ERRORED;
    if (!mod.has_eval_error) {
        mod.eval_error.set_undefined();
        heap.tval_copy_ref(&mod.eval_error, error);
        mod.has_eval_error = true;
    }
    module_close_cycle(mod);
    module_settle_eval_promise(heap, vm, mod, false);

    for (uint i = 0; i < mod.async_parent_count; i++) {
        ModuleDef* parent = mod.async_parents[i];
        if (parent == null) continue;
        module_async_execution_rejected(heap, vm, parent, error);
    }
}

// ============================================================================
// Tarjan strongly-connected components
// ============================================================================
//
// The DFS that evaluates modules doubles as Tarjan's SCC search. A module is
// pushed when its traversal begins and popped as part of a component when the
// traversal that reached it completes; the component's root is the module whose
// lowlink never escaped its own discovery index. Threading the stack through
// stack_prev keeps this allocation-free.

ModuleDef* module_dfs_stack = null;
uint module_dfs_counter = 0;
uint module_dfs_depth = 0;

// Begin `mod`'s traversal: assign its discovery index, seed its lowlink, and
// push it on the DFS stack.
fn void module_dfs_push(ModuleDef* mod) {
    mod.dfs_index = module_dfs_counter;
    mod.dfs_ancestor_index = module_dfs_counter;
    module_dfs_counter++;
    mod.stack_prev = module_dfs_stack;
    mod.on_stack = true;
    module_dfs_stack = mod;
}

// ECMA-262 InnerModuleEvaluation step 16: if `mod` roots a component, pop it
// and stamp every member -- `mod` included -- as belonging to `mod`. A member
// that is still asynchronously evaluating leaves the stack with the rest (its
// traversal IS finished) but takes EVALUATING_ASYNC rather than EVALUATED, so
// a later importer waits for it instead of reading it as complete.
fn void module_close_cycle(ModuleDef* mod) {
    if (mod == null || !mod.on_stack) return;
    if (mod.dfs_ancestor_index != mod.dfs_index) return;
    while (true) {
        ModuleDef* member = module_dfs_stack;
        if (member == null) break;
        module_dfs_stack = member.stack_prev;
        member.stack_prev = null;
        member.on_stack = false;
        member.cycle_root = mod;
        if (member.status == ModuleStatus.EVALUATING) {
            member.status = ModuleStatus.EVALUATED;
        }
        if (member == mod) break;
    }
}

// ECMA-262 ExecuteAsyncModule / ExecuteModule: run `mod`'s body, now that its
// import bindings are in place and every async dependency has landed.
//
// Three shapes, one contract: the module either finishes here, or suspends and
// finishes later through module_async_execution_fulfilled/rejected. Both paths
// converge on the same status transition and the same waiter settlement, so no
// caller has to know which happened.
fn bool module_run_body(Heap* heap, Vm* vm, ModuleDef* mod) {
    // Relative specifiers in a dynamic import() issued from this body resolve
    // against this module, not against whoever triggered the evaluation.
    char[] saved_module_name = heap.current_module_name;
    heap.current_module_name = mod.module_name;
    defer heap.current_module_name = saved_module_name;

    if (mod.func != null) {
        HObject* pending = null;
        bool failed = false;

        if (vm.run_depth > 0) {
            // Mid-dispatch (reached from a dynamic import handled inline).
            // execute_module_async/execute_in_env commandeer activations[0]
            // and valstack[0]; only the nested entry point is re-entrant.
            bool? ok = vm.execute_module_nested(mod.func, mod.env, &pending);
            if (catch ok) { failed = true; } else { failed = !ok; }
        } else if (mod.func.is_async()) {
            bool? ok = vm.execute_module_async(mod.func, mod.env, &pending);
            if (catch ok) { failed = true; } else { failed = !ok; }
        } else {
            TVal? res = vm.execute_in_env(mod.func, mod.env);
            if (catch res) { failed = true; }
        }

        if (failed) return module_record_eval_error(heap, vm, mod);

        if (pending != null) {
            // Top-level await suspended. The module's traversal is complete
            // even though its body is not, so it is already (or is about to
            // be) EVALUATING_ASYNC; settlement arrives through the reactions
            // attached here, which route into the same two handlers a
            // dependency's settlement would.
            module_ensure_eval_promise(heap, mod);
            module_attach_async_settlement(heap, mod, pending);
            // execute_module_async handed over its pinning reference; the
            // reactions just attached hold their own through `pending`.
            heap.decref(pending.as_header());
            return true;
        }
    }

    module_async_execution_fulfilled(heap, vm, mod);
    return true;
}

// ECMA-262 §16.2.1.6.1.3 InnerModuleEvaluation: evaluate `mod`, recursing
// through its dependencies first.
//
// This is also the Tarjan SCC search (see module_close_cycle). The two jobs
// share one traversal because they need the same information: which modules are
// still on the stack (cycle members) and which have finished (dependencies to
// wait on or read errors from).
//
// Returns false only for a synchronous failure, with the thrown value on the
// heap error channel. An asynchronous failure -- a rejected top-level await,
// anywhere in the subgraph -- returns true here and reports later through
// module_async_execution_rejected, because by then this call has long returned.
fn bool execute_module(Heap* heap, Vm* vm, ModuleDef* mod) {
    // A finished module speaks through its component's root: a sibling that ran
    // its own body successfully before the root threw is EVALUATED, yet an
    // import of it must still re-reject with the component's error.
    ModuleDef* root = module_cycle_root(mod);
    if (root.status == ModuleStatus.ERRORED) {
        heap.error_value.set_undefined();
        heap.tval_copy_ref(&heap.error_value, &root.eval_error);
        heap.has_error = true;
        return false;
    }
    if (mod.status == ModuleStatus.EVALUATED) return true;
    if (mod.status == ModuleStatus.ERRORED) {
        heap.error_value.set_undefined();
        heap.tval_copy_ref(&heap.error_value, &mod.eval_error);
        heap.has_error = true;
        return false;
    }
    // Already being traversed (a cycle back-edge) or already async: either way
    // its evaluation is under way and this call must not restart it.
    if (mod.status == ModuleStatus.EVALUATING ||
        mod.status == ModuleStatus.EVALUATING_ASYNC) return true;

    // A JSON module has no body; its `default` binding was installed at resolve
    // time, so it is complete the moment it is reached.
    if (mod.is_json) {
        mod.status = ModuleStatus.EVALUATED;
        call_on_module_evaluated(heap, mod);
        return true;
    }

    mod.status = ModuleStatus.EVALUATING;
    mod.pending_async_deps = 0;
    module_dfs_push(mod);
    module_dfs_depth++;
    defer {
        module_dfs_depth--;
        if (module_dfs_depth == 0) module_dfs_counter = 0;
    }

    // Parent the module env to the global env so globals stay visible inside
    // the module. The normal pipeline links (and roots) this first; this branch
    // only runs for a module evaluated without a prior link.
    if (mod.env == null) {
        EnvRecord*? env_opt = env::env_create_declarative(heap, vm.global_env);
        if (catch err = env_opt) return false;
        mod.env = env_opt;
        if (mod.env.bindings != null) {
            heap.register_gc_root(mod.env.bindings.as_header());
        }
    }

    // Dependencies first, so their exports exist before the body runs. A
    // type-only import was erased wholesale (mark_type_only_req_modules) and is
    // not a dependency here.
    // Walk in evaluation order, which is the entry order except where a
    // request first seen as `import defer` was later imported eagerly and so
    // took the eager import's position (see ReqModuleEntry.eval_order). Those
    // values are unique but not contiguous, so select the smallest not yet
    // taken rather than indexing by slot.
    uint req_count = (uint)mod.req_modules.len();
    uint prev_order = 0;
    bool have_prev = false;
    for (uint slot = 0; slot < req_count; slot++) {
        uint i = req_count;
        uint best = 0;
        for (uint j = 0; j < req_count; j++) {
            uint ord = mod.req_modules[j].eval_order;
            if (have_prev && ord <= prev_order) continue;
            if (i == req_count || ord < best) { i = j; best = ord; }
        }
        if (i == req_count) break;
        prev_order = best;
        have_prev = true;
        ReqModuleEntry* rme = &mod.req_modules[i];
        if (rme.type_only || rme.resolved == null) continue;
        // A `import defer` edge contributes no evaluation and no ordering:
        // the target runs on first access to its deferred namespace, which
        // may be never. Skipping it here is what keeps its side effects out
        // of the importer's evaluation, and skipping the lowlink propagation
        // below is what keeps it out of the importer's cycle component.
        //
        // Only a fully synchronous subgraph can be deferred, though: forcing
        // happens inside an ordinary property read, which has nowhere to
        // await, so a target with top-level await (or one reachable from it)
        // is evaluated eagerly here at its normal place in the order.
        if (rme.deferred) {
            module_defer_scan_epoch++;
            if (!module_subgraph_is_async((ModuleDef*)rme.resolved)) continue;
        }
        ModuleDef* dep = (ModuleDef*)rme.resolved;

        if (!execute_module(heap, vm, dep)) {
            return module_record_eval_error(heap, vm, mod);
        }

        // Step 11.c.iii/iv, the two mutually exclusive shapes of an edge:
        if (dep.on_stack && dep.status == ModuleStatus.EVALUATING) {
            // Back-edge to an ancestor still being traversed: `mod` and `dep`
            // are in one component. Propagating the lowlink is what leaves
            // dfs_ancestor_index == dfs_index on the component's root alone.
            if (dep.dfs_ancestor_index < mod.dfs_ancestor_index) {
                mod.dfs_ancestor_index = dep.dfs_ancestor_index;
            }
        } else if (dep.on_stack) {
            // A cycle peer that has already finished its own descent and become
            // async: it is still on the stack (the component is not closed yet)
            // but it is genuinely running, so `mod` must wait for it exactly
            // like any other async dependency. Without this a cycle's members
            // all start before any of them finishes.
            if (dep.dfs_ancestor_index < mod.dfs_ancestor_index) {
                mod.dfs_ancestor_index = dep.dfs_ancestor_index;
            }
            if (dep.async_eval_order == AsyncEvalOrder.ORDERED) {
                if (module_add_async_parent(heap, dep, mod)) {
                    mod.pending_async_deps++;
                }
            }
        } else {
            // Cross-edge into a finished component. Its root owns the outcome.
            ModuleDef* dep_root = module_cycle_root(dep);
            if (dep_root.status == ModuleStatus.ERRORED) {
                heap.error_value.set_undefined();
                heap.tval_copy_ref(&heap.error_value, &dep_root.eval_error);
                heap.has_error = true;
                return module_record_eval_error(heap, vm, mod);
            }
            // Still running means `mod` cannot run yet. Count the dependency
            // and record the reverse edge that will decrement it again.
            if (dep_root.async_eval_order == AsyncEvalOrder.ORDERED) {
                if (module_add_async_parent(heap, dep_root, mod)) {
                    mod.pending_async_deps++;
                }
            }
        }
    }

    // A module with top-level await, or one waiting on async dependencies, gets
    // its place in the async ordering now -- at DFS discovery time, which is
    // precisely what makes the ordering observable as traversal order.
    bool has_tla = mod.func != null && mod.func.has_tla();
    if (has_tla || mod.pending_async_deps > 0) {
        module_take_async_order(mod);
        module_ensure_eval_promise(heap, mod);
        // Mark async BEFORE running: a cycle peer whose descent reaches this
        // module while its body is in flight must see a module that is running
        // asynchronously (and so wait for it), not one still being traversed.
        mod.status = ModuleStatus.EVALUATING_ASYNC;
        // Only run now if nothing is outstanding; otherwise the last
        // dependency to settle will run this body through
        // module_async_execution_fulfilled.
        if (mod.pending_async_deps == 0) {
            if (!module_execute_continue(heap, vm, mod)) return false;
        }
        // Traversal is complete either way: close the component so `mod` and
        // its cycle peers leave the stack as EVALUATING_ASYNC rather than
        // lingering as apparent cycle ancestors.
        module_close_cycle(mod);
        return true;
    }

    if (!module_execute_continue(heap, vm, mod)) return false;
    module_close_cycle(mod);
    return true;
}

// ECMA-262 InitializeEnvironment + ExecuteModule: resolve `mod`'s import
// bindings against its now-evaluated dependencies, then run its body. Called
// from execute_module when nothing blocks the module, and from the batch in
// module_async_execution_fulfilled when the last dependency it was waiting on
// finishes -- which is that module's first chance to bind, so both paths must
// come through here rather than jumping straight to module_run_body.
fn bool module_execute_continue(Heap* heap, Vm* vm, ModuleDef* mod) {
    // Resolve import bindings against (now-executed) source modules. Both
    // `import * as ns` and named `import { x }` install LIVE accessor
    // bindings (ECMA-262 §16.2.1.6.2/§10.4.6): reads always re-resolve
    // through to the source module's current env value, so a later
    // mutation in the source module is observed by the importer and by
    // the namespace object without any re-copy step. See
    // install_live_binding for the shared implementation.
    for (uint i = 0; i < (uint)mod.imports.len(); i++) {
        ImportEntry* ie = &mod.imports[i];
        if (ie.req_module_idx >= (uint)mod.req_modules.len()) continue;
        ReqModuleEntry* rme = &mod.req_modules[ie.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* source_mod = (ModuleDef*)rme.resolved;

        if (ie.is_star) {
            // `import * as ns from '...'`, build a Module Namespace Object --
            // or, for `import defer * as ns`, the deferred one, whose first
            // string-keyed access evaluates the module.
            HObject*? ns_opt = build_namespace_object(heap, source_mod, ie.is_deferred);
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
            // Unresolvable (null/ambiguous). validate_imports rejects this at
            // link time, so reaching here means the module was NOT validated:
            // link_module returns early for a dependency already in LINKING or
            // EVALUATING status (a cycle, including a self-import), and such a
            // module's imports are only resolvable once the outermost link
            // completes. Fall back to identity resolution against the direct
            // source module so those get a binding rather than none at all.
            // A TS importer's type-only name (erased export) installs no
            // binding; every reference to it was erased too.
            if (module_is_ts(mod)) continue;
            char[] src_local_name = resolve_export_local_name(source_mod, ie.import_name);
            install_live_binding(heap, mod.env, local_key, source_mod, src_local_name);
        }
    }

    // NOTE: an indirect export (`export { x } from './other'`) intentionally
    // installs NO binding in mod.env. ECMA-262 §16.2.1.6.2 InitializeEnvironment
    // only creates bindings for ImportEntries and local (non-indirect)
    // ExportEntries; a re-exported name is never a resolvable identifier
    // inside the re-exporting module's own body (it is only observable
    // externally via ResolveExport / the module's namespace object, both of
    // which resolve indirect exports directly through the export-entry
    // which resolve indirect exports directly through the export-entry
    // metadata). Declaring one here as a live accessor instead makes it a
    // spurious local identifier: an internal `B;` reference (where
    // `export { A as B } from './x'` re-exports a not-yet-initialized `A`)
    // resolves through this binding as a TDZ read rather than an
    // unresolved-reference ReferenceError, and because the accessor's getter
    // runs via vm.heap.call_fn's re-entrant nested Vm.run (vm_call_fn_impl),
    // a TDZ throw surfacing from a second read of that same accessor inside an
    // enclosing catch handler (e.g. `catch (e) { arr.push(e.name, typeof B) }`)
    // escapes past the still-live outer catcher instead of propagating as the
    // plain uncaught-reference behavior real engines produce.

    return module_run_body(heap, vm, mod);
}


// ============================================================================
// Top-level entry point
// ============================================================================

// Load, link, and evaluate a module program given its file path.
//
// `path` is used both to read the top-level module source and as the base
// name against which relative imports (`./x.js`) are resolved, so it must be
// the module file's real path (absolute or relative to cwd). Drives the full
// resolve -> link -> evaluate pipeline.
//
// Return values (an int rather than a fault so the caller can distinguish
// the failure kind, mirroring the worker's exec_js contract):
//   0 = evaluated successfully
//   1 = a runtime error was thrown during evaluation of the module or one of
//       its dependencies. The thrown value is left in `heap.error_value` so
//       the caller (e.g. the test harness) can inspect its type.
//   2 = the module (or a dependency) failed to load/compile/link.
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

    // A dynamic import() enqueues its resolve/link/evaluate pipeline as a job
    // rather than running inline (see dynamic_import), and mod itself may
    // still be asynchronously evaluating here (a TLA body, or a dependency
    // of one. See execute_module's async_dep chaining) rather than settled.
    // This is the top-level entry point for running a module program
    // directly, so it must drain those jobs out (and any further jobs they
    // enqueue) before returning, or a top-level `import()`, or the module's
    // own top-level await, never completes. Not reentrant with any outer
    // drain (this only runs at true top level).
    for (int drain_i = 0; drain_i < 1000; drain_i++) {
        uint before = heap.microtask_count;
        heap.drain_microtasks((void*)vm);
        uint after = heap.microtask_count;
        if (after == 0) break;
        if (after == before && drain_i > 5) break;
    }

    // mod's own evaluation may have settled asynchronously during the drain
    // above (a rejected top-level await, or a rejected async dependency it
    // was transitively chained onto) rather than synchronously inside the
    // execute_module call above, check its final status now.
    if (mod.status == ModuleStatus.ERRORED) {
        heap.error_value.set_undefined();
        heap.has_error = false;
        if (mod.has_eval_error) {
            heap.tval_copy_ref(&heap.error_value, &mod.eval_error);
            heap.has_error = true;
            return 1;
        }
        return 2;
    }
    return 0;
}

// ============================================================================
// Dynamic import: `import(specifier)` (ES2020)
// ============================================================================

// Resolve, link and evaluate the module named by `specifier` and return a
// Promise (as a TVal carrying one caller-owned reference, the caller must
// decref after storing it) that fulfills with the module's namespace object
// or rejects with the module's load/evaluation error. Load and evaluation
// failures reject the returned promise; a fault means promise allocation
// itself failed.
//
// Relative specifiers resolve against the running module's name: the
// currently executing function's filename when it has one, else
// heap.current_module_name (maintained by execute_module around body runs).
// Capture the current thrown value out of every error channel into a
// caller-owned `*out` and clear the channels, so a pending fault does not
// leak past the point where it is turned into a promise rejection. When no
// value is present, `*out` is set to a fresh TypeError with `fallback_msg`.
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

// Validate the ES2025 import-call options argument and its `with` attributes
// (§13.3.10 EvaluateImportCall / GetImportAttributes). Returns true on
// success. On any abrupt completion (non-object options/with, a throwing
// `with` getter or `ownKeys`, or a non-String attribute value) returns false
// with `*reason` set to a caller-owned rejection value and every error
// channel cleared. `options` may be undefined (no attributes → success).
//
// Attributes are validated but not otherwise applied: this engine's loader
// carries no per-attribute behavior beyond the already-supported JSON module
// type inferred from the specifier, so a well-formed `with` clause is a
// no-op here (matching the module resolution level already in place).
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

    // keys = OwnPropertyKeys(attributesObj), proxy `ownKeys` may throw.
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
        // with is_symbol set, skip it (and never invoke its getter).
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

// Build a Promise (as a TVal carrying one caller-owned reference, the caller
// must decref after storing it) already rejected with `reason`. Used by the
// DYN_IMPORT opcode for the IfAbruptRejectPromise steps of §13.3.10: an abrupt
// completion from evaluating the specifier or from ToString(specifier) does
// not throw synchronously; it rejects the returned promise instead. On promise
// allocation failure returns a fault.
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

// Hidden property keys carrying a queued dynamic-import job's captured
// state (ES2020 §13.3.10 and HostImportModuleDynamically): the load,
// link, and evaluate steps run as a separate job, not inline with the
// `import()` call that requested them).
const char[] DYN_IMPORT_SPEC_KEY  = "\xFFdi_spec";
const char[] DYN_IMPORT_BASE_KEY  = "\xFFdi_base";
const char[] DYN_IMPORT_JSON_KEY  = "\xFFdi_json";
// `import.defer(x)`: the resolved module is bound to its deferred namespace
// and is not evaluated by the import itself (ES2025 import-defer).
const char[] DYN_IMPORT_DEFER_KEY  = "\xFFdi_defer";
const char[] DYN_IMPORT_PROM_KEY  = "\xFFdi_promise";

// `import(specifier)` (ES2020 §13.3.10, ES2015+ HostImportModuleDynamically).
// Synchronously allocates and returns the result promise, then defers the
// entire resolve → link → evaluate → settle pipeline to a queued
// DYNAMIC_IMPORT_JOB microtask (mirroring PromiseResolveThenableJob), per
// spec, dynamic import starts a new job rather than running inline with the
// calling module's own (possibly still in-progress) static evaluation, and
// running it inline let import() observably preempt that static DFS order.
fn TVal? dynamic_import(Heap* heap, Vm* vm, char[] specifier, bool wants_json = false, bool deferred = false) {
    HObject*? prom_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return MODULE_ERROR~;
    HObject* prom = prom_raw;
    prom.prototype = heap.promise_proto;
    builtins::promise_init(prom);
    prom.as_header().incref();  // caller-owned reference

    // Base name for relative resolution: the currently executing function's
    // filename when it has one, else the module whose body is currently
    // running (maintained by execute_module around body runs). Must be
    // captured now, synchronously, because by the time the job runs the calling
    // frame may no longer be live.
    char[] base_name = {};
    if (vm.current_func != null) base_name = vm.current_func.get_filename();
    if (base_name.len == 0) base_name = heap.current_module_name;

    // Intern both strings so the job can read them back after the calling
    // frame, and the original specifier's backing string, may be gone.
    // Interned HStrings are heap-owned and rooted through the string table for
    // as long as the job object references them.
    HString* spec_key  = heap.str_intern(DYN_IMPORT_SPEC_KEY);
    HString* base_key   = heap.str_intern(DYN_IMPORT_BASE_KEY);
    HString* json_key   = heap.str_intern(DYN_IMPORT_JSON_KEY);
    HString* defer_key  = heap.str_intern(DYN_IMPORT_DEFER_KEY);
    HString* prom_key   = heap.str_intern(DYN_IMPORT_PROM_KEY);
    HString* spec_str   = heap.str_intern(specifier);
    HString* base_str   = base_name.len > 0 ? heap.str_intern(base_name) : null;
    if (spec_key == null || base_key == null || json_key == null || prom_key == null || spec_str == null) {
        TVal oom_reason = module_type_error(heap, "out of memory resolving module specifier");
        builtins::promise_settle(prom, builtins::PROMISE_REJECTED, &oom_reason, heap);
        builtins::promise_trigger_reactions(prom, heap, (void*)vm);
        TVal oom_result;
        oom_result.set_object(prom);
        return oom_result;
    }

    HObject*? job_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = job_raw) {
        TVal oom_reason = module_type_error(heap, "out of memory scheduling dynamic import");
        builtins::promise_settle(prom, builtins::PROMISE_REJECTED, &oom_reason, heap);
        builtins::promise_trigger_reactions(prom, heap, (void*)vm);
        TVal oom_result;
        oom_result.set_object(prom);
        return oom_result;
    }
    HObject* job = job_raw;
    job.flags.callable = true;
    job.flags.constructable = false;
    job.prototype = heap.function_proto;
    (*job.extra_ptr()).func.builtin_fn_index = (int)Builtin.DYNAMIC_IMPORT_JOB.ordinal;

    TVal spec_tv; spec_tv.set_string(spec_str);
    job.put_prop(spec_key, spec_tv, hobject::PROP_FLAGS_WEC, heap);
    if (base_str != null) {
        TVal base_tv; base_tv.set_string(base_str);
        job.put_prop(base_key, base_tv, hobject::PROP_FLAGS_WEC, heap);
    }
    TVal json_tv; json_tv.set_boolean(wants_json);
    job.put_prop(json_key, json_tv, hobject::PROP_FLAGS_WEC, heap);
    TVal defer_tv; defer_tv.set_boolean(deferred);
    job.put_prop(defer_key, defer_tv, hobject::PROP_FLAGS_WEC, heap);
    TVal prom_tv; prom_tv.set_object(prom);
    job.put_prop(prom_key, prom_tv, hobject::PROP_FLAGS_WEC, heap);

    TVal job_tv; job_tv.set_object(job);
    TVal undef_arg; undef_arg.set_undefined();
    TVal undef_downstream; undef_downstream.set_undefined();
    heap.enqueue_microtask(job_tv, undef_arg, undef_downstream);

    TVal result;
    result.set_object(prom);
    return result;
}

// Microtask handler for DYNAMIC_IMPORT_JOB. Reads the deferred
// specifier/base/wants_json/promise off ctx.callee_obj's hidden slots and
// performs the resolve → link → evaluate pipeline. If the module's
// evaluation is still pending when execute_module returns (an async/TLA
// module whose completion this job, itself running inside a microtask
// drain, cannot poll to settlement), attaches a DYNAMIC_IMPORT_FINISH
// reaction to the module's persistent eval_promise instead; otherwise
// settles/builds the namespace object immediately.
fn void builtin_dynamic_import_job(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    Vm* vm = (Vm*)ctx.vm;
    ctx.result.set_undefined();
    if (ctx.callee_obj == null) return;

    HString* spec_key = heap.str_intern(DYN_IMPORT_SPEC_KEY);
    HString* base_key = heap.str_intern(DYN_IMPORT_BASE_KEY);
    HString* json_key = heap.str_intern(DYN_IMPORT_JSON_KEY);
    HString* defer_key = heap.str_intern(DYN_IMPORT_DEFER_KEY);
    HString* prom_key = heap.str_intern(DYN_IMPORT_PROM_KEY);
    if (spec_key == null || base_key == null || json_key == null || prom_key == null) return;

    char[] spec_data = {};
    if (try sv = ctx.callee_obj.get_prop(spec_key, ctx.heap)) {
        if (sv.is_string()) spec_data = ((HString*)sv.get_heapptr()).get_data();
    }
    char[] base_data = {};
    if (try bv = ctx.callee_obj.get_prop(base_key, ctx.heap)) {
        if (bv.is_string()) base_data = ((HString*)bv.get_heapptr()).get_data();
    }
    bool wants_json = false;
    if (try jv = ctx.callee_obj.get_prop(json_key, ctx.heap)) {
        if (jv.is_boolean()) wants_json = jv.get_boolean();
    }
    bool deferred = false;
    if (defer_key != null) {
        if (try dv = ctx.callee_obj.get_prop(defer_key, ctx.heap)) {
            if (dv.is_boolean()) deferred = dv.get_boolean();
        }
    }
    HObject* prom = null;
    if (try pv = ctx.callee_obj.get_prop(prom_key, ctx.heap)) {
        if (pv.is_object() && pv.get_heapptr() != null) prom = (HObject*)pv.get_heapptr();
    }
    if (prom == null) return;

    TVal reason;
    reason.set_undefined();
    bool rejected = false;
    // True when `reason` holds a reference we own (copied out of an error
    // channel) that must be dropped after promise_settle increfs its own copy.
    bool clear_reason_ref = false;

    ModuleDef* mod = null;
    heap.has_error = false;
    heap.error_value.set_undefined();
    ModuleDef*? mod_opt = resolve_module(heap, spec_data, base_data, wants_json, true);
    if (catch err = mod_opt) {
        // A load failure may have parked a specific static-semantics error
        // (SyntaxError for a module parse failure) on the heap error channel.
        // Prefer it over the generic TypeError, and clear the channel so the
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
            // heap error channel, prefer it over the generic TypeError, and
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

    // `import.defer(x)` resolves and links the module but does not evaluate it:
    // the promise fulfills with the deferred namespace, and the body runs on
    // the first triggering access like the static form.
    // Same rule as the static form: only a fully synchronous subgraph can be
    // deferred, so `import.defer()` of a module with top-level await (or one
    // reachable from it) evaluates it before fulfilling.
    if (deferred) {
        module_defer_scan_epoch++;
        if (module_subgraph_is_async(mod)) deferred = false;
    }

    if (!rejected && deferred) {
        HObject*? dns_opt = build_namespace_object(heap, mod, true);
        TVal dns_val;
        if (catch err = dns_opt) {
            dns_val = module_type_error(heap, "cannot build deferred module namespace object");
            builtins::promise_settle(prom, builtins::PROMISE_REJECTED, &dns_val, heap);
        } else {
            dns_val.set_object(dns_opt);
            builtins::promise_settle(prom, builtins::PROMISE_FULFILLED, &dns_val, heap);
        }
        builtins::promise_trigger_reactions(prom, heap, (void*)vm);
        return;
    }

    if (!rejected) {
        heap.has_error = false;
        heap.error_value.set_undefined();
        bool ok = execute_module(heap, vm, mod);
        if (!ok) {
            if (heap.has_error || heap.error_value.is_object() || heap.error_value.is_string()) {
                // Take ownership of the thrown value: copy it out, then clear
                // every error channel so the VM does not see a lingering
                // fault once this job returns. Without this the drain loop's
                // next iteration (or the caller of drain_microtasks) would
                // observe a spurious uncaught throw unrelated to it.
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
        return;
    }

    if (mod.status != ModuleStatus.EVALUATED) {
        // Still EVALUATING: an async/TLA subgraph suspended and this job
        // (itself inside a microtask drain) could not pump the queue to
        // settlement. See execute_module_async/nested. execute_module
        // already chained mod.eval_promise onto the per-call pending promise
        // in this case (see its `pending != null` branch), and
        // module_settle_eval_promise fulfills eval_promise with the
        // module's namespace object specifically so this adoption needs no
        // separate "then build the namespace" step: `prom` simply adopts
        // eval_promise's eventual settlement (namespace object, or the
        // rejection reason) directly, via the same mechanism used for a
        // native Promise resolution (ES6 §25.4.1.3.2 steps 9-12).
        HObject* eval_prom = module_ensure_eval_promise(heap, mod);
        if (eval_prom == null) {
            TVal oom_reason = module_type_error(heap, "out of memory awaiting module evaluation");
            builtins::promise_settle(prom, builtins::PROMISE_REJECTED, &oom_reason, heap);
            builtins::promise_trigger_reactions(prom, heap, (void*)vm);
            return;
        }
        builtins::promise_adopt_native(heap, (void*)vm, eval_prom, prom);
        return;
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
}

// ============================================================================
// Helpers
// ============================================================================

// Build a TypeError value with the given message, for rejecting a dynamic
// import promise. On allocation failure returns an undefined TVal, a
// degraded rejection reason is acceptable since the promise is still
// rejected.
fn TVal module_type_error(Heap* heap, char[] msg) {
    return module_error_with_proto(heap, heap.type_err_proto, msg);
}

// Build a SyntaxError value for a module static-semantics failure (a link-phase
// early error such as an ambiguous or circular indirect export). ECMA-262
// surfaces these as SyntaxError.
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
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC, heap);
        }
    }
    result.set_object(err);
    return result;
}

// Resolve an export name to the local binding name in a module's exports table.
// For most exports local_name == export_name, but for `export default <expr>`
// the compiler emits local_name="*default*" and export_name="default".
fn char[] resolve_export_local_name(ModuleDef* mod, char[] export_name) {
    for (uint i = 0; i < (uint)mod.exports.len(); i++) {
        ExportEntry* ee = &mod.exports[i];
        if (!ee.is_indirect && char_slice_eq(ee.export_name, export_name)) {
            return ee.local_name;
        }
    }
    return export_name; // fallback: identity
}

// Resolve a ModuleDef.exports entry to the module and local binding name
// that actually OWNS the value, following one level of indirection for
// `export { x } from './other'` (ee.local_name there names a binding in
// the OTHER module, not in `mod`'s own env). Direct exports resolve to
// `mod` itself (with `resolve_export_local_name` applied for the
// `export default` "*default*" rename). Used by build_namespace_object so
// every export, direct or re-exported, installs a live accessor against
// its true owning env, never a same-module self-reference for indirect
// entries.
//
// Returns { null, {} } when the indirection's target module isn't
// resolved (e.g. a load failure), callers should treat that as
// "value unavailable" (undefined).
struct ExportBindingSource {
    ModuleDef* owner;
    char[]     local_name;
}
fn ExportBindingSource resolve_export_binding_source(ModuleDef* mod, ExportEntry* ee) {
    if (!ee.is_indirect) {
        return { mod, ee.local_name };
    }
    if (ee.req_module_idx >= (uint)mod.req_modules.len()) {
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

// Install a LIVE binding named `dest_key` in `dest_env`: reading it always
// re-resolves `src_local_name` in `source_mod.env.bindings` at access time.
// Shared by named imports, indirect re-exports, and (via
// build_namespace_object) namespace exports. This is the one place that answers
// "read this binding live" for the whole module pipeline.
//
// Falls back to a plain `undefined` data binding when the source module has
// no env yet (e.g. a failed dependency), interning fails, or the target
// would be a direct self-reference (dest_env.bindings/dest_key identical to
// the source slot, as in a self-import of a name this module does not
// actually declare, such as one reachable only via an unresolved `export *`
// star-export). A self-pointing accessor's getter would call back into
// itself and recurse forever; since the slot never independently holds a
// value in that case, `undefined` is the correct (and only sane) result
// anyway.
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
        // Accessor allocation failed, degrade to a one-time snapshot rather
        // than leaving the binding entirely undeclared.
        TVal? val_opt = env::env_get(source_mod.env, src_key);
        TVal val;
        if (catch err = val_opt) { val.set_undefined(); } else { val = val_opt; }
        env::env_declare(dest_env, dest_key, val);
        return;
    }
    env::env_declare_accessor(dest_env, dest_key, accessor);
}

// Byte-wise comparison of two identifier slices, used to sort namespace
// export keys into code-unit order (ECMA-262 §10.4.6.9). UTF-8 byte order
// agrees with UTF-16 code-unit order for the entire BMP (all codepoints
// below U+10000); it only diverges from true UTF-16 order for astral
// export names mixed with codepoints in U+E000-U+FFFF, an accepted edge
// case in this engine.
fn bool export_name_less(char[] a, char[] b) {
    usz n = a.len < b.len ? a.len : b.len;
    for (usz i = 0; i < n; i++) {
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.len < b.len;
}

// One resolved exported name contributing to a namespace object's own keys.
// `entry` is the owning module's ExportEntry when the name comes from a direct
// or indirect export (used to follow `export {x} from` / `export * as ns`
// indirection); it is null for a name reached purely through a `export *` star
// re-export, in which case `local_name` names a binding directly in `owner_mod`.
struct NsExportItem {
    char[]     export_name;
    ModuleDef* owner_mod;
    char[]     local_name;
    ExportEntry* entry;
}

// True if `name` is already among the collected namespace items.
fn bool ns_has_export_name(List{NsExportItem}* items, char[] name) {
    for (uint i = 0; i < (uint)items.len(); i++) {
        if (char_slice_eq((*items)[(sz)i].export_name, name)) return true;
    }
    return false;
}

// Append a namespace export item unless its name is already present (nearer
// exports shadow star-reached ones).
fn void ns_add_export_item(List{NsExportItem}* items,
                           char[] export_name, ModuleDef* owner_mod, ExportEntry* entry) {
    if (ns_has_export_name(items, export_name)) return;
    items.push({ export_name, owner_mod, entry != null ? entry.local_name : export_name, entry });
}

// Expand `export *` star re-exports (§16.2.3.7 GetExportedNames) into the
// namespace item list, transitively. For each star-target module, every one of
// its exported names EXCEPT `default` is added (if not already present) as a
// live binding into that target's own env, direct exports keep their owning
// ExportEntry (so indirect/namespace re-exports still resolve correctly),
// while names the target itself only re-exports via its own `export *` are
// added as plain bindings in the target. `depth` guards against import cycles.
fn void collect_star_export_items(ModuleDef* mod, List{NsExportItem}* items, uint depth) {
    collect_star_export_items_from(mod, mod, items, depth);
}

// Implementation of collect_star_export_items: `root` is the module whose
// namespace is being built (fixed across the whole recursion, GetModuleNamespace
// always resolves ambiguity relative to it, ECMA-262 §16.2.1.6.3), `mod` is
// the current module being scanned for `export *` targets.
fn void collect_star_export_items_from(ModuleDef* root, ModuleDef* mod,
                                       List{NsExportItem}* items, uint depth) {
    if (depth > MAX_STAR_EXPORTS) return;
    for (uint si = 0; si < (uint)mod.star_exports.len(); si++) {
        StarExportEntry* se = &mod.star_exports[si];
        if (se.req_module_idx >= (uint)mod.req_modules.len()) continue;
        ReqModuleEntry* rme = &mod.req_modules[se.req_module_idx];
        if (rme.resolved == null) continue;
        ModuleDef* target = (ModuleDef*)rme.resolved;
        for (uint ei = 0; ei < (uint)target.exports.len(); ei++) {
            ExportEntry* ee = &target.exports[ei];
            // `export *` never re-exports the default binding (§16.2.3.7 step 4).
            if (char_slice_eq(ee.export_name, "default")) continue;
            // A name reached through two or more distinct star paths with
            // different owning bindings is ambiguous (§16.2.1.6.3 steps 9-10).
            // It is left out of the namespace object entirely, rather than
            // resolved to whichever star export was visited first.
            ResolveSetEntry[RESOLVE_SET_MAX] amb_rset;
            ResolveExportResult amb_rr = resolve_export(root, ee.export_name, &amb_rset[0], 0);
            if (amb_rr.kind == ResolveExportKind.AMBIGUOUS) continue;
            ns_add_export_item(items, ee.export_name, target, ee);
        }
        // Transitively include the target's own star re-exports.
        collect_star_export_items_from(root, target, items, depth + 1);
    }
}

// Return the import.meta object for `mod`, creating it on first access
// (ECMA-262 §13.3.12 ImportMeta Evaluation + §16.2.1.10 [[ImportMeta]]).
//
// The object is an ordinary object with a null [[Prototype]] (matching the
// HostGetImportMetaProperties conventions the test262 corpus assumes) and a
// single host-provided `url` data property (writable/enumerable/configurable)
// holding the module's normalized name. It is cached on the ModuleDef so every
// evaluation of the module observes the same identity, and distinct modules
// get distinct objects. The cache holds a ModuleDef-owned reference (rooted by
// mark_roots) for the module's lifetime.
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
            meta.put_prop(url_key, url_val, hobject::PROP_FLAGS_WEC, heap);
        }
    }

    // Root for the module's lifetime and cache for identity.
    meta.as_header().incref();
    mod.import_meta_obj = meta;
    return meta;
}

// Build a Module Namespace Object for `import * as ns`.
// The returned HObject has one own enumerable property per export of
// source_mod, installed as a LIVE accessor via install_live_binding's
// shared machinery (make_module_binding_accessor) so a later mutation of
// the exported binding in source_mod is observed through ns.x /
// Object.keys(ns) / for-in without re-building the namespace.
//
// Own string keys are inserted in sorted code-unit order so enumeration
// (which walks the prop table in insertion order) yields the spec-required
// sorted order; @@toStringTag is the only symbol key and is added last.
fn HObject*? build_namespace_object(Heap* heap, ModuleDef* source_mod, bool deferred = false) {
    // A module has exactly one Module Namespace Object (ECMA-262 §10.4.6.12
    // GetModuleNamespace: cached in module.[[Namespace]]). Repeated `import * as`
    // / dynamic imports of the same module must observe the SAME object
    // identity, build it once and cache it on the ModuleDef.
    //
    // `deferred` builds the Deferred Module Namespace Exotic Object instead
    // (ES2025 import-defer), cached in its own slot because [[Namespace]] and
    // [[DeferredNamespace]] are separate: a module imported both ways in one
    // graph has two objects. The two are identical apart from
    // exotic_deferred_ns, which makes a string-keyed MOP operation evaluate
    // the module before answering -- so the export set, the sort order and
    // the live-binding accessors are all built here, once, for both.
    if (deferred) {
        if (source_mod.deferred_namespace_obj != null) {
            return source_mod.deferred_namespace_obj;
        }
    } else if (source_mod.namespace_obj != null) {
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
    ns.flags.exotic_deferred_ns = deferred;

    // Cache for identity BEFORE populating exports: a self-referential
    // `export * as ns from './self'` (or a cyclic star-as re-export) would
    // otherwise recurse into build_namespace_object for the same module and
    // never terminate. Caching now means the recursive call returns this
    // in-progress (still-empty) object, matching the spec's single
    // GetModuleNamespace object per module. Root it for the ModuleDef's lifetime.
    ns.as_header().incref();
    if (deferred) {
        source_mod.deferred_namespace_obj = ns;
    } else {
        source_mod.namespace_obj = ns;
    }

    // Collect the full exported-name set (§10.4.6.9 [[OwnPropertyKeys]] iterates
    // GetExportedNames): the module's own direct/indirect exports plus the names
    // reached transitively through `export *` star re-exports. `default` is
    // never re-exported by a star (§16.2.3.7). Names already contributed by a
    // nearer export win (star names are only added if not already present).
    List{NsExportItem} items;
    items.allocator = mem;
    for (uint i = 0; i < (uint)source_mod.exports.len(); i++) {
        ExportEntry* ee = &source_mod.exports[i];
        ns_add_export_item(&items, ee.export_name, source_mod, ee);
    }
    collect_star_export_items(source_mod, &items, 0);

    // Sort collected items by export_name into code-unit order (§10.4.6.9).
    for (uint i = 1; i < (uint)items.len(); i++) {
        NsExportItem tmp = items[i];
        int j = (int)i - 1;
        while (j >= 0 && export_name_less(tmp.export_name, items[(sz)j].export_name)) {
            items[(sz)(j + 1)] = items[(sz)j];
            j--;
        }
        items[(sz)(j + 1)] = tmp;
    }

    for (uint oi = 0; oi < (uint)items.len(); oi++) {
        NsExportItem* it = &items[oi];
        HString* export_key = heap.str_intern(it.export_name);
        if (export_key == null) continue;

        // Namespace re-export (`export * as ns from './other'`): the export
        // entry's local name is "*", meaning the exported value is the TARGET
        // module's own namespace object (built recursively), installed as a
        // static data property {enumerable:true, configurable:false}, not a
        // live env binding accessor. (§16.2.3.7 / GetModuleNamespace.)
        if (it.entry != null && it.entry.is_indirect && char_slice_eq(it.entry.local_name, "*")
            && it.entry.req_module_idx < (uint)it.owner_mod.req_modules.len()) {
            ReqModuleEntry* rme = &it.owner_mod.req_modules[it.entry.req_module_idx];
            if (rme.resolved != null) {
                ModuleDef* target = (ModuleDef*)rme.resolved;
                HObject*? nested_opt = build_namespace_object(heap, target);
                if (catch nerr = nested_opt) {
                    TVal undef; undef.set_undefined();
                    ns.put_prop(export_key, undef, hobject::PROP_FLAGS_NEC, heap);
                    continue;
                }
                TVal nested_tv; nested_tv.set_object(nested_opt);
                ns.put_prop(export_key, nested_tv, hobject::PROP_FLAGS_NEC, heap);
                continue;
            }
            TVal undef; undef.set_undefined();
            ns.put_prop(export_key, undef, hobject::PROP_FLAGS_NEC, heap);
            continue;
        }

        // Resolve to the module/local-name that actually owns the value via
        // the full ResolveExport algorithm (ECMA-262 16.2.1.6.3): an item
        // reached through `export { x } from` may itself point at an
        // indirect or star-only export in the target module (a re-export
        // chain, possibly cyclic back through this very module), and a
        // single level of indirection is not enough to reach the true owner.
        // The named-import resolution below this loop works the same way.
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
            // Allocation failure or missing env, degrade to a static
            // undefined data property rather than dropping the export key.
            TVal undef; undef.set_undefined();
            ns.put_prop(export_key, undef, hobject::PROP_FLAGS_NEC, heap);
            continue;
        }

        // Export bindings are {enumerable:true, configurable:false} data-view
        // semantics implemented as an accessor per the [[Get]] live-binding
        // requirement; [[Writable]] is meaningless for accessors (the
        // namespace has no [[Set]], plain field left false by PROP_FLAGS
        // convention below).
        hobject::PropFlags acc_flags = { .writable = false, .enumerable = true, .configurable = false, .is_accessor = true };
        ns.put_prop(export_key, accessor, acc_flags, heap);
    }

    // ns[Symbol.toStringTag] === "Module", {writable:false, enumerable:false, configurable:false}
    // per ECMA-262 §28.3 (Module Namespace Object requirements). Inserted
    // last so it sorts after all string keys per §10.4.6.9 (symbols always
    // follow strings in [[OwnPropertyKeys]] regardless of insertion order).
    HString* tostrtag_sym = builtins::ensure_tostringtag_symbol(heap);
    if (tostrtag_sym != null) {
        TVal tag_val;
        // A deferred namespace reports "Deferred Module" so it is
        // distinguishable from an evaluated one without touching a string key
        // (which would force evaluation). The tag is fixed at construction and
        // does not change when the module is later forced.
        tag_val.set_string(builtins::builtin_intern_string(heap,
            deferred ? "Deferred Module" : "Module"));
        ns.put_prop(tostrtag_sym, tag_val, hobject::PROP_FLAGS_NNC, heap);
    }

    // Module namespace exotic objects are not extensible (ECMA-262 §10.4.6):
    // [[IsExtensible]] always returns false and [[PreventExtensions]] is a
    // no-op success. Set the flag after all own properties are installed.
    ns.flags.extensible = false;

    return ns;
}

// True when evaluating `mod` would be asynchronous: it has top-level await,
// or some module reachable from it does.
//
// ES2025 import-defer defers only fully synchronous subgraphs. An async
// module cannot be forced on demand -- the triggering access is an ordinary
// property read with nowhere to await -- so a deferred edge into one is
// evaluated eagerly instead, at its normal place in the importer's order
// (test262 import-defer/evaluation-top-level-await).
//
// The visit stamp terminates the walk: every module is entered at most once
// per query, so a cycle or a diamond is followed only until each edge has
// been seen, and no separate depth bound is needed.
fn bool module_subgraph_is_async(ModuleDef* mod) {
    if (mod == null) return false;
    if (mod.func != null && mod.func.has_tla()) return true;
    if (mod.defer_scan_mark == module_defer_scan_epoch) return false;
    mod.defer_scan_mark = module_defer_scan_epoch;
    for (uint i = 0; i < (uint)mod.req_modules.len(); i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        if (rme.type_only || rme.resolved == null) continue;
        // A nested `import defer` edge keeps its own deferral, so an async
        // module behind one does not make THIS subgraph async.
        if (rme.deferred) continue;
        if (module_subgraph_is_async((ModuleDef*)rme.resolved)) return true;
    }
    return false;
}

// True when `mod` or anything it would evaluate is already on the stack.
//
// Forcing a deferred namespace runs the whole eager subgraph, so a module
// anywhere in it that is mid-evaluation makes the force impossible: the
// evaluation the read is waiting for cannot complete. Detecting that BEFORE
// starting is what keeps the failure side-effect free -- test262
// import-defer/errors/get-other-while-dep-evaluating requires that a sibling
// dependency is not evaluated on the way to discovering the cycle.
//
// Shares module_defer_scan_epoch with module_subgraph_is_async; callers bump
// it before each top-level query.
fn bool module_subgraph_is_evaluating(ModuleDef* mod) {
    if (mod == null) return false;
    if (mod.status == ModuleStatus.EVALUATING
        || mod.status == ModuleStatus.EVALUATING_ASYNC) return true;
    if (mod.defer_scan_mark == module_defer_scan_epoch) return false;
    mod.defer_scan_mark = module_defer_scan_epoch;
    for (uint i = 0; i < (uint)mod.req_modules.len(); i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        if (rme.type_only || rme.resolved == null) continue;
        // A nested deferred edge is not evaluated by this force, so a module
        // in flight behind one does not block it.
        if (rme.deferred) continue;
        if (module_subgraph_is_evaluating((ModuleDef*)rme.resolved)) return true;
    }
    return false;
}

// Epoch for module_subgraph_is_async's visit stamps, bumped per top-level
// query so a stamp from an earlier scan never suppresses a later one.
uint module_defer_scan_epoch = 0;

// heap::ForceDeferredNsFn bridge, installed by the VM at startup so the
// prototype-chain walk in hobject can trigger deferral without importing the
// module subsystem.
fn bool force_deferred_namespace_bridge(void* heap_ptr, void* vm_ptr, void* ns) {
    return force_deferred_namespace((Heap*)heap_ptr, vm_ptr, (HObject*)ns);
}

// True when `key` is one that must NOT force a deferred namespace.
//
// Symbols never trigger, which keeps Symbol.toStringTag readable. "then" is
// the other exception: a deferred namespace is thenable-probed whenever it
// reaches Promise.resolve or an `await`, and evaluating on that probe would
// make merely awaiting the namespace defeat the deferral (test262
// import-defer/evaluation-triggers/ignore-*-then-*).
fn bool deferred_trigger_exempt_key(HString* key) {
    if (key == null) return true;
    if (key.is_symbol()) return true;
    return key.equals("then");
}

// Force evaluation of the module behind a Deferred Module Namespace Exotic
// Object (ES2025 import-defer), if `ns` is one and it has not run yet.
//
// Every string-keyed MOP operation on a deferred namespace calls this first:
// [[Get]], [[GetOwnProperty]], [[HasProperty]], [[Delete]], [[Set]],
// [[DefineOwnProperty]] and [[OwnPropertyKeys]]. Symbol keys and the
// prototype/extensibility operations deliberately do not, which is what makes
// `ns[Symbol()]`, `Object.getPrototypeOf(ns)` and `Object.isExtensible(ns)`
// observable without evaluating (test262 import-defer/evaluation-triggers).
//
// Evaluation is synchronous and transitive only through eager edges: a
// deferred sub-dependency of the module keeps its own deferral, so touching
// `ns` runs this module and its eager dependencies and stops there.
//
// Returns false when evaluation threw; the error is on the heap channel and
// the caller propagates it like any other.
fn bool force_deferred_namespace(Heap* heap, void* vm_ptr, HObject* ns) {
    if (ns == null || !ns.flags.exotic_deferred_ns) return true;
    ModuleDef* mod = deferred_namespace_owner(heap, ns);
    if (mod == null) return true;
    // An evaluated module needs no further work, and the namespace can drop
    // the flag for good: from here it behaves as an ordinary one.
    if (mod.status == ModuleStatus.EVALUATED) {
        ns.flags.exotic_deferred_ns = false;
        return true;
    }

    // A module that already failed rethrows the SAME error value on every
    // later access, so a deferred namespace and an earlier eager import of
    // the same module report one identical object (§16.2.1.5.3, and test262
    // import-defer/errors/module-throws).
    if (mod.status == ModuleStatus.ERRORED) {
        if (mod.has_eval_error) {
            heap.tval_copy_ref(&heap.error_value, &mod.eval_error);
            heap.has_error = true;
        } else {
            TVal err = module_type_error(heap, "module evaluation failed");
            heap.error_value = err;
            heap.has_error = true;
        }
        return false;
    }

    // Already running: the access came from the module's own body, or from a
    // cycle peer's, and there is no way to complete the evaluation the read
    // is asking for. §16.2.1.10 makes that a TypeError rather than exposing a
    // half-initialized namespace. The flag stays set -- the module may yet
    // finish, and a later access should see an ordinary namespace.
    module_defer_scan_epoch++;
    if (module_subgraph_is_evaluating(mod)) {
        TVal err = module_type_error(heap,
            "cannot access a deferred module namespace while the module is evaluating");
        heap.error_value = err;
        heap.has_error = true;
        return false;
    }

    // Evaluating now. Clear the flag for the duration: the module body can
    // reach its own deferred namespace, directly or around a cycle, and
    // re-entering here would recurse forever. A read during the body then
    // sees an ordinary namespace, whose TDZ accessors report an unfinished
    // binding correctly on their own.
    ns.flags.exotic_deferred_ns = false;
    bool ok = execute_module(heap, (Vm*)vm_ptr, mod);
    // A failed evaluation restores the flag so every later access comes back
    // through here and rethrows the cached error, rather than reading an
    // ordinary namespace over a module that never ran (test262
    // import-defer/errors/module-throws/trigger-evaluation).
    if (!ok) ns.flags.exotic_deferred_ns = true;
    return ok;
}

// Find the module a Deferred Module Namespace Exotic Object stands for.
//
// A plain OBJECT carries no extra-data slot to hold the ModuleDef, and giving
// every object one to serve this case is not worth it, so the owner is
// recovered by scanning the module cache. The scan runs at most once per
// deferred module: the first triggering access evaluates it, and evaluation
// clears the flag, so later reads take the ordinary namespace path.
fn ModuleDef* deferred_namespace_owner(Heap* heap, HObject* ns) {
    if (heap.module_cache == null) return null;
    ModuleDef** cache = (ModuleDef**)heap.module_cache;
    for (uint i = 0; i < heap.module_cache_count; i++) {
        ModuleDef* mod = cache[i];
        if (mod != null && mod.deferred_namespace_obj == ns) return mod;
    }
    return null;
}

fn bool char_slice_eq(char[] a, char[] b) {
    if (a.len != b.len) return false;
    for (usz i = 0; i < a.len; i++) {
        if (a[i] != b[i]) return false;
    }
    return true;
}
