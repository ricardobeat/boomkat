# Plan 037: ESM Import/Export Support

**Status:** Proposed
**Priority:** High — unlocks ~755 test262 `module-code/` tests, plus `dynamic-import` and `import.meta` features
**Reference:** QuickJS `quickjs.c` (lines ~880–929 for `JSModuleDef`, ~31508–31841 for import/export parsing, ~30334–30618 for linking)

## Problem

The engine has no module system. `import` and `export` are recognized keywords (`TokenType.IMPORT`/`EXPORT` at `lexer.c3:58`) but the compiler's `statement()` dispatch (`statements.c3:17`) has no cases for them — they fall through to `expression_statement()` and fail. There are ~755 test262 `language/module-code/` tests plus dynamic-import tests that are currently skipped or failing.

## Architecture Summary

QuickJS compiles modules as an async function body where all top-level declarations and import bindings are closure variables. This engine has no closure-variable infrastructure — it uses `EnvRecord` scope chains with name-based `GETVAR`/`DECLVAR`/`PUTLEX`. The plan uses the existing env system: each module gets a declarative `EnvRecord` that holds both its local declarations and its resolved import bindings. Exports are metadata entries pointing at env bindings.

**Module lifecycle** (mirrors QuickJS):
```
1. COMPILE:  compile_module() → parse import/export → emit bytecode → ModuleDef
2. RESOLVE:  load all transitive dependencies (recursive compile_module)
3. LINK:     share env bindings between modules for live exports
4. EXECUTE:  run module body (top-level statements)
5. NAMESPACE: build Module Namespace Object for `import *`
```

**Key design decisions:**
- No new opcodes for static import/export — `GETVAR`/`DECLVAR`/`PUTLEX` on the module env handle everything. Only `import()` dynamic import needs a new opcode.
- Module env is declarative (`env_create_declarative`), not object env. Matches spec (modules always strict, no `with`).
- Module body runs in its own env, not the global env. This isolates module bindings.
- Bare specifiers (`import 'lodash'`) need a host callback — the engine can't resolve bare specifiers without a module resolution policy.
- `"use strict"` is a no-op — modules are always strict (already the engine's only mode).
- Circular imports: handled by a `LOADING` status check — if a module is encountered while it's still loading, its partially-initialized env is returned (matches Node.js/QuickJS).

---

## Phase 1: Data Structures

**Files:** new `src/module.c3`, `src/heap.c3`, `src/bytecode.c3`

### New module definition structs (`src/module.c3`)

```c3
module duktape::module;

import duktape::types;
import duktape::bytecode;
import duktape::env;
import duktape::heap;
import duktape::hobject;

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
}

struct StarExportEntry {
    uint req_module_idx;    // index into ModuleDef.req_modules
}

struct ReqModuleEntry {
    char[]       module_name;   // the specifier string
    ModuleDef*?  resolved;      // filled during resolve phase
}

enum ModuleStatus : char {
    UNLOADED,
    LOADING,       // currently being compiled (cycle detection)
    LOADED,        // compiled, not yet linked
    LINKING,       // being linked
    LINKED,        // ready for evaluation
    EVALUATING,    // being executed
    EVALUATED,     // fully executed
}

struct ModuleDef {
    char[]                module_name;    // normalized path / identifier
    ModuleStatus          status;

    // Import/export metadata (populated during compilation)
    ImportEntry*          imports;
    uint                  import_count;
    ExportEntry*          exports;
    uint                  export_count;
    StarExportEntry*      star_exports;
    uint                  star_export_count;
    ReqModuleEntry*       req_modules;
    uint                  req_module_count;

    // Compiled bytecode for this module's body
    CompiledFunction*     func;

    // Runtime environment holding this module's bindings
    EnvRecord*            env;

    // Module namespace object (lazily created for `import *`)
    HObject*              namespace_obj;
}
```

### Heap additions (`src/heap.c3`)

- `ModuleDef** loaded_modules` — module cache (growable array)
- `uint loaded_module_count`
- `uint loaded_module_cap`
- `fn ModuleDef*? find_loaded_module(&self, char[] name)` — linear scan by name
- `fn ModuleDef*? new_module_def(&self, char[] name)` — allocates and registers

### FuncFlags addition (`src/bytecode.c3`)

- Add `bool is_module : 20` to `FuncFlags` bitstruct

---

## Phase 2: Compiler Context Changes

**File:** `src/compiler/context.c3`

Add to `CompilerContext`:
- `bool is_module` — true when compiling a module
- `ModuleDef* current_module` — pointer to the module being compiled

These enable the parser to record import/export entries into the correct ModuleDef.

---

## Phase 3: Compiler — Parsing Import

**File:** `src/compiler/statements.c3`

### 3a. `statement()` dispatch

Add two cases to the switch at line 20:
```c3
case TokenType.IMPORT:
    self.import_declaration()!;
case TokenType.EXPORT:
    self.export_declaration()!;
```

### 3b. `import_declaration()` (new function)

Parse all ES6 import forms per spec §15.2.2:

| Form | Parsing |
|------|---------|
| `import 'module'` | side-effect only — register `ReqModuleEntry`, no bindings |
| `import defaultName from 'module'` | `import_name="default"`, `local_name=<ident>` |
| `import { a, b as c } from 'module'` | iterate `{...}`, record each pair |
| `import * as ns from 'module'` | `import_name="*"`, `is_star=true` |
| `import defaultName, { a } from 'module'` | parse default, then fall through to `{` or `*` |

After parsing, the compiler:
1. Registers a `ReqModuleEntry` for the specifier string
2. For each import binding, calls `self.add_import_binding(local_name, import_name, req_idx, is_star)` which:
   - Emits `DECLVAR` to declare the local name in the module env
   - Records the `ImportEntry` in the `current_module`

**Disambiguation note:** `import(...)` (dynamic import call) and `import.meta` are handled in `primary_expr` (expressions.c3), not here. The `IMPORT` token at statement level always starts a static import declaration. Need to verify that `import(...)` is correctly handled — check if `primary_expr` has a case for `TokenType.IMPORT` that handles `import(...)` as a call expression. If not, add it there too.

---

## Phase 4: Compiler — Parsing Export

**File:** `src/compiler/statements.c3`

### `export_declaration()` (new function)

Parse all ES6 export forms per spec §15.2.3:

| Form | Handling |
|------|----------|
| `export function foo() {}` | parse function decl via `function_declaration()`, record `ExportEntry{local="foo", export="foo"}` |
| `export class Foo {}` | parse class decl, record `ExportEntry{local="Foo", export="Foo"}` |
| `export const/let/var x = ...` | parse var decl, record `ExportEntry` for each declarator |
| `export { a, b as c }` | record `ExportEntry{local="a", export="a"}`, `{local="b", export="c"}` |
| `export { a } from './other'` | record as indirect: `is_indirect=true`, `req_module_idx=...` |
| `export * from './other'` | record `StarExportEntry{req_idx}` |
| `export * as ns from './other'` | record `ExportEntry{local="*", export="ns", is_indirect=true}` |
| `export default function() {}` | parse with synthetic name `*default*`, record `ExportEntry{local="*default*", export="default"}` |
| `export default <expr>` | emit `DECLVAR *default* = <expr>`, record export |
| `export default class {}` | same pattern as default function |

**Async/generator export:** `export async function foo()` and `export function* foo()` — parse with the async/generator flags, then record export entry.

---

## Phase 5: `compile_module()` Entry Point

**File:** `src/compiler/entry.c3`

```c3
fn CompiledFunction*? compile_module(Lexer* lex, void* heap, char[] module_name) {
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;       // top-level declarations go to module env
    ctx.is_module = true;       // enables import/export parsing

    Heap* hp = (Heap*)heap;
    ModuleDef* mod = hp.find_or_create_module(module_name);
    ctx.current_module = mod;

    // Parse directives, hoist, parse statements (same as compile())
    ctx.parse_directives()!;
    ctx.hoist_global_fn_decls()!;
    ctx.hoist_decls(true)!;
    // ... restore lexer, parse statements ...

    // For modules, return undefined (no implicit last-expression return)
    ctx.emit_simple(Opcode.RETUNDEF);

    CompiledFunction*? result = ctx.finish()!;
    if (try func = result) {
        func.flags.is_module = true;
    }
    mod.func = result;
    return result;
}
```

Key differences from `compile()`:
- Sets `ctx.is_module = true`
- Sets `ctx.current_module` to the ModuleDef
- Emits `RETUNDEF` (modules return `undefined`, not the last expression)
- Sets `func.flags.is_module = true`

---

## Phase 6: Pluggable Module Host API

**Files:** new `src/module.c3` (types + host callback definitions), new `src/module_loader.c3` (engine-side resolve/link/execute), `src/heap.c3` (registration)

The module system is split into two layers:

1. **Engine layer** (`module_loader.c3`): parsing, linking, execution — deterministic, spec-compliant, not customizable
2. **Host layer** (`module.c3` callback interface): file I/O, name resolution, module cache policy — fully pluggable

This mirrors the existing `AllocFunc`/`FreeFunc`/`FatalFunc` callback pattern on `Heap` (`heap.c3:17`). The host (CLI, embedded runtime, test harness) registers callbacks; the engine calls them at the right points.

### 6a. Host callback struct (`src/module.c3`)

```c3
/// Host callbacks for module loading. The engine calls these at the
/// appropriate points in the module lifecycle. All are optional — if
/// NULL, a default implementation is used (or an error is raised).
struct ModuleHostHooks {
    /// Resolve a module specifier to a normalized name.
    /// Called with the importing module's name (base) and the raw
    /// specifier string from the `import`/`export ... from` source.
    /// Returns the normalized name (owned by host, must survive until
    /// module is unloaded) or null on error.
    /// Default: `default_module_normalize` (relative path resolution).
    fn char[]?(fn_arg resolve_name)(
        char[] base_name,
        char[] specifier,
        void*  udata
    );

    /// Read module source code from a normalized name.
    /// Returns the source text (owned by host) or null on error.
    /// The engine does NOT free this pointer — the host owns it.
    /// Default: `default_module_read` (reads file from disk via libc::fopen).
    fn char[]?(fn_arg read_source)(
        char[] normalized_name,
        void*  udata
    );

    /// Called after a module is fully compiled. The host can attach
    /// metadata, register the module in its own cache, etc.
    /// Optional — may be NULL.
    fn void?(fn_arg on_module_loaded)(
        ModuleDef* mod,
        void*      udata
    );

    /// Called after a module is fully evaluated (executed).
    /// Optional — may be NULL.
    fn void?(fn_arg on_module_evaluated)(
        ModuleDef* mod,
        void*      udata
    );

    /// User data passed to all callbacks (opaque to the engine).
    void* udata;
}
```

### 6b. Default implementations (`src/module_loader.c3`)

```c3
/// Default name resolver: relative path normalization.
/// "./foo" resolves relative to base_name's directory.
/// Bare specifiers (no leading "./" or "../") are returned as-is.
fn char[]? default_module_normalize(char[] base_name, char[] specifier, void* udata) {
    if (!starts_with_dot(specifier)) return specifier;
    // Extract dirname of base_name, join with specifier
    // Normalize path separators to '/'
    // Return the result
}

/// Default source reader: read file from disk via libc::fopen/fread/fclose.
fn char[]? default_module_read(char[] normalized_name, void* udata) {
    // libc::fopen(normalized_name, "r")
    // libc::fread into buffer
    // libc::fclose
    // Return buffer contents
}
```

### 6c. Registration on Heap (`src/heap.c3`)

Add to `Heap`:
```c3
    // Module host hooks (pluggable from host side)
    ModuleHostHooks* module_hooks;
```

And a registration function:
```c3
/// Register module host hooks. Call before any module loading.
/// Pass NULL to use defaults. The hooks pointer must remain valid
/// for the lifetime of the Heap.
fn void Heap.set_module_hooks(&self, ModuleHostHooks* hooks) {
    self.module_hooks = hooks;
}
```

The engine always calls through the hooks:
```c3
// In resolve_module:
char[] normalized;
if (heap.module_hooks != null && heap.module_hooks.resolve_name != null) {
    normalized = heap.module_hooks.resolve_name(base_name, specifier, heap.module_hooks.udata)!;
} else {
    normalized = default_module_normalize(base_name, specifier, null)!;
}

// In load_module:
char[] source;
if (heap.module_hooks != null && heap.module_hooks.read_source != null) {
    source = heap.module_hooks.read_source(normalized_name, heap.module_hooks.udata)!;
} else {
    source = default_module_read(normalized_name, null)!;
}
```

### 6d. Resolution & loading pipeline

```c3
fn ModuleDef*? resolve_module(Heap* heap, char[] specifier, char[] base_name) {
    // 1. Normalize name via host hook
    char[] normalized = call_resolve_name(heap, base_name, specifier);

    // 2. Check engine cache
    ModuleDef*? cached = heap.find_loaded_module(normalized);
    if (cached != null) return cached;

    // 3. Read source via host hook
    char[] source = call_read_source(heap, normalized);
    if (source == null) return null; // host declined to load

    // 4. Compile
    Lexer lex;
    lex.init(source, normalized);
    CompiledFunction*? func = compile_module(&lex, heap, normalized);
    ModuleDef* mod = heap.find_loaded_module(normalized); // compile_module registered it

    // 5. Notify host
    call_on_module_loaded(heap, mod);

    // 6. Recursively resolve dependencies
    for (uint i = 0; i < mod.req_module_count; i++) {
        ReqModuleEntry* rme = &mod.req_modules[i];
        rme.resolved = resolve_module(heap, rme.module_name, normalized)!;
    }

    mod.status = ModuleStatus.LOADED;
    return mod;
}
```

### 6e. Host usage example (CLI)

```c3
// In benchmarks/duktape_c3.c3 --module mode:

// Use defaults (file-based loading, relative path normalization)
// No hooks needed — engine uses default_module_normalize + default_module_read

// OR: custom hooks for a bundled runtime:
ModuleHostHooks hooks;
hooks.resolve_name = my_bundler_resolve;  // maps "lodash" → "/bundle/lodash.js"
hooks.read_source  = my_bundler_read;     // reads from in-memory bundle
hooks.on_module_loaded = null;
hooks.on_module_evaluated = null;
hooks.udata = &my_bundle;
heap.set_module_hooks(&hooks);
```

### 6f. Linking & execution (unchanged)

Linking and execution are engine-internal — not pluggable. They always follow the spec:
- `link_module()` resolves import bindings from the source module's env
- `execute_module()` runs the module body in its own env, dependencies first
- `build_module_namespace()` creates the `import *` namespace object

The host can observe these phases via `on_module_loaded` / `on_module_evaluated` callbacks but cannot alter the linking semantics.

---

## Phase 7: VM Changes

**Files:** `src/vm/vm_lifecycle.c3`, `src/vm/vm_execute.c3`

### 7a. `execute_in_env` (new, in `vm_lifecycle.c3`)

Similar to existing `execute()` but passes the module's `EnvRecord` as the function's `var_env`/`lex_env` instead of creating a fresh function scope:

```c3
fn TVal? Vm.execute_in_env(&self, CompiledFunction* func, EnvRecord* env) {
    // Same as execute() but:
    // - act.var_env = env
    // - act.lex_env = env
    // - Skip env_create_function_scope
}
```

### 7b. `import()` dynamic import (new opcode, deferred)

Add `IMPORT_DYN` opcode:
- **Format**: ABC — A=result_reg, B=specifier_reg, C=0
- **VM handler**: Creates a Promise, enqueues a microtask to resolve+load+execute the module, resolves the promise with the module namespace object

This can be deferred to a later phase after static imports work.

---

## Phase 8: CLI Integration

**File:** `benchmarks/duktape_c3.c3`

Add a `--module` / `-m` flag:
```
duktape_c3 --module ./entry.js
```

When `--module` is passed:
1. Calls `compile_module()` instead of `compile()`
2. Runs `resolve_module()` → `link_module()` → `execute_module()`
3. The entry module's exports are accessible via the namespace object

Add a `just run-module` recipe:
```just
run-module file:
    just build duktape_c3 && ./out/duktape_c3 --module {{file}}
```

---

## Phase 9: Live Bindings

QuickJS achieves live bindings by sharing `JSVarRef` pointers between modules. This engine uses `EnvRecord` bindings (HObject properties).

**Phase 1 (initial)**: Import bindings are copied at link time. Mutations to exports are NOT visible to importers. This passes most test262 tests but fails `live-binding` tests.

**Phase 2 (upgrade)**: Import bindings reference the same `EnvRecord` entry. When resolving an import, instead of copying the value, the importing module's env gets a property that is a getter/setter pointing at the exporting module's binding. This achieves live binding without VarRef infrastructure.

**Recommendation**: Implement Phase 1 first, upgrade to Phase 2 when live-binding test262 tests become relevant.

---

## test262 Impact

- **~755 tests** in `test/language/module-code/` — currently all failing/skipped
- **Dynamic import tests** — in various phases, currently skipped
- **`import.meta` tests** — small count, can be added as follow-up
- **Skip list changes**: remove `"module-code"` from any skip dirs (it's not there currently — tests are simply failing at compile time). Add `"import-defer"`, `"export-defer"`, `"import-attributes"`, etc. to skip features (already done in `test262_skip.cfg`).

---

## Implementation Order

| Step | What | Files | ~Lines |
|------|------|-------|--------|
| 1 | Data structures (ModuleDef, ImportEntry, ExportEntry, etc.) | new `src/module.c3`, `src/heap.c3`, `src/bytecode.c3` | 200 |
| 2 | Compiler flags (`is_module`, `current_module`) | `src/compiler/context.c3` | 10 |
| 3 | `compile_module()` entry point | `src/compiler/entry.c3` | 60 |
| 4 | `import_declaration()` parser | `src/compiler/statements.c3` | 200 |
| 5 | `export_declaration()` parser | `src/compiler/statements.c3` | 300 |
| 6 | `statement()` dispatch for IMPORT/EXPORT | `src/compiler/statements.c3` | 6 |
| 7 | Module loader & resolver | new `src/module_loader.c3` | 200 |
| 8 | Module linker (binding resolution) | `src/module_loader.c3` | 100 |
| 9 | VM `execute_in_env` | `src/vm/vm_lifecycle.c3` | 50 |
| 10 | CLI `--module` flag | `benchmarks/duktape_c3.c3` | 40 |
| 11 | `import()` dynamic import | `src/vm/vm_execute.c3`, `src/bytecode.c3` | 100 |
| 12 | Live bindings (Option B) | `src/module_loader.c3`, `src/env.c3` | 150 |

**Total: ~1,400 lines** of new code across 4-5 new/existing files.

---

## Validation

1. **Minimal repro**: Create `test/mod_main.js`:
   ```js
   import { add } from './mod_utils.js';
   add(1, 2);
   ```
   And `test/mod_utils.js`:
   ```js
   export function add(a, b) { return a + b; }
   ```
   Run: `just run-module test/mod_main.js`

2. **Rosetta**: `just rosetta` — must remain 44/44 (no regressions)

3. **test262 phase 0**: `just test262-phase 0` — no regressions (modules aren't tested in phase 0)

4. **Module-specific test**: Create `test/test_module_basic.js` with import/export assertions, run via `just run-module`

5. **test262 module-code**: `python3 scripts/run_test262.py --phase module-code` (or equivalent) to measure pass rate on the 755 module tests
