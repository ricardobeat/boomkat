module boomkat::compiler;

import boomkat::types;
import boomkat::relexstats;
import boomkat::lexer;
import boomkat::ast;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;
import std::collections::list;

// The import name standing for the spec's ~source~ binding, as "*" stands for
// a namespace. Neither is a valid exported name, so neither can collide with
// one. Must match module::SOURCE_BINDING.
const char[] SOURCE_BINDING = "%source%";

struct CompImportEntry {
    char[] local_name;
    char[] import_name;
    uint   req_module_idx;
    bool   is_star;
    bool   is_default;
    // `import defer * as ns` (ES2025 import-defer). Layout must match
    // module::ImportEntry.
    bool   is_deferred;
    // `import source x from` (ES2025 source-phase-imports).
    bool   is_source;
}

struct CompExportEntry {
    char[] local_name;
    char[] export_name;
    bool   is_indirect;
    uint   req_module_idx;
    bool   is_lexical;      // true for a local `let`/`const`/`class` export
    // True when the export came from an `export`-PREFIXED declaration
    // (`export var x = 1`, `export function f(){}`, `export class C {}`,
    // `export var {a, b} = o`) rather than an `export { x }` clause. Such an
    // export declares its own binding in the same statement, so it trivially
    // satisfies the §16.2.1.1 ExportedBindings rule and
    // check_module_exports_resolvable skips it — the binding may be a
    // destructuring leaf that no name pre-scan reconstructs.
    bool   declares_binding;
}

struct CompStarExportEntry {
    uint req_module_idx;
}

// The `type` of an import attribute clause, selecting how the referenced file
// becomes a module. Every non-NONE type is a synthetic module whose sole export
// is `default` (CreateDefaultExportSyntheticModule); the file is never compiled
// as ECMAScript. Backed by `char` so the layout matches module::ReqModuleEntry,
// which mirrors this struct field for field.
enum ModuleAttrType : char {
    NONE,   // no `type` attribute: compile the file as ECMAScript
    JSON,   // `with { type: "json" }`  -> JSON.parse of the contents
    TEXT,   // `with { type: "text" }`  -> the contents as a UTF-8 String
    BYTES,  // `with { type: "bytes" }` -> a Uint8Array over an immutable buffer
}

struct CompReqModuleEntry {
    char[] module_name;
    void*  resolved;
    // The `type` the import specifier asked for, selecting the load path for
    // the referenced file. Layout must match module::ReqModuleEntry.
    ModuleAttrType attr_type;
    // Set at link time when the statement's bindings were all type-only (see
    // module::ReqModuleEntry.type_only). Layout must match module::ReqModuleEntry.
    bool   type_only;
    // True while every import of this specifier is `import defer`. Layout must
    // match module::ReqModuleEntry.deferred.
    bool   deferred;
    // Position in the module's evaluation order. Normally the entry's own
    // index; a request first seen as `import defer` and later imported
    // eagerly moves to the eager import's position. Layout must match
    // module::ReqModuleEntry.eval_order.
    uint   eval_order;
}

// --- for-of and for-await-of codegen ---
// All for-of loops share one skeleton (emit_forof); only what happens to each
// yielded value differs. ForOfHead is a tagged union describing that per-value
// step. `is_await` on emit_forof selects the sync vs async iterator protocol,
// the loop shape is otherwise identical.
enum ForOfKind {
    IDENT,        // for (x of e) / for (let x of e) / for (const x of e) / for (var x of e)
    DESTRUCTURE,  // for ([a] of e) / for ({x} of e), lexical-declared or bare-assignment
    MEMBER,       // for (obj.p of e)
}

struct ForOfHead {
    ForOfKind kind;

    // IDENT: bind the value to a single variable.
    ushort id_reg;         // loop-variable register (declared/allocated by caller)
    uint   id_name_idx;    // constant index of the variable name
    bool   id_is_bare;     // true = assign to existing lvalue, no declaration
    // Bare target that resolves to a register-cached local: id_reg is that
    // local's HOME register, so the bind writes the value straight into it (and
    // skips PUTVAR). Without this the body, which reads the local from its home
    // register, would see a stale value, since PUTVAR only updates the env slot
    // and then clears its source register (see the bare-forof var-desync fix).
    bool   id_reg_resident;
    // Ident declaration whose binding was already on the scope stack — most
    // commonly a sloppy catch body's B.3.5 reuse of the catch parameter, whose
    // binding lives in the catch's lex_env above the var_env the per-iteration
    // emit_var_store would otherwise write to with DECLVAR. Walks the chain.
    bool   id_walk_chain;

    // Shared by IDENT and DESTRUCTURE.
    bool   is_lexical;     // let/const (needs per-iteration env)
    bool   is_const;

    // DESTRUCTURE: extract the value through a pattern via emit_destructure.
    // The caller owns the binds, which are pointed at val_slot per iteration.
    // store_mode is DECLARE (let/const/var decl) or ASSIGN_TARGET (bare
    // assignment pattern).
    DestructBind[] binds;
    DestructStoreMode store_mode;
    bool           is_object_pattern;

    // MEMBER: re-parse and store into a member reference each iteration.
    uint ast_target;
}

// Layout must match module::FuncDeclEntry.
struct CompFuncDeclEntry {
    char[] name;
    uint   inner_func_idx;
}

// Compiler-side view of ModuleDef, field layout must match module::ModuleDef.
// The metadata lists are growable (see ModuleDef's note) and come
// pre-initialized by the module loader; the compiler only pushes into them.
struct CompModuleDef {
    char[]                                module_name;
    char                                  status;
    List{CompImportEntry}                 imports;
    List{CompExportEntry}                 exports;
    List{CompStarExportEntry}             star_exports;
    List{CompReqModuleEntry}              req_modules;
    List{CompFuncDeclEntry}               func_decls;
}

// Register a top-level module function declaration for eager link-time
// instantiation (deduplicates by name, a later declaration of the same
// name replaces the earlier inner_func_idx, mirroring last-wins hoisting).
fn void mod_register_func_decl(CompModuleDef* mod, char[] name, uint inner_func_idx) {
    for (uint i = 0; i < (uint)mod.func_decls.len(); i++) {
        if (str_eq(mod.func_decls[i].name, name)) {
            mod.func_decls[i].inner_func_idx = inner_func_idx;
            return;
        }
    }
    mod.func_decls.push({ name, inner_func_idx });
}

// Register a required module specifier, returning its index (deduplicates).
fn uint mod_register_req_module(CompModuleDef* mod, char[] specifier, ModuleAttrType attr_type = ModuleAttrType.NONE, bool deferred = false) {
    for (uint i = 0; i < (uint)mod.req_modules.len(); i++) {
        // Imports of the same specifier under different `type` attributes are
        // distinct module requests (different [[Attributes]]), so only reuse
        // an entry whose type matches too.
        if (mod.req_modules[i].attr_type == attr_type &&
            str_eq(mod.req_modules[i].module_name, specifier)) {
            // The request stays deferred only while EVERY import of it is:
            // one eager import makes the module evaluate in dependency order
            // (test262 module-imported-defer-and-eager). It also takes that
            // eager import's POSITION -- the entry keeps its index, since
            // ImportEntry.req_module_idx points at it, and records the order
            // separately.
            if (!deferred && mod.req_modules[i].deferred) {
                mod.req_modules[i].deferred = false;
                mod.req_modules[i].eval_order = (uint)mod.req_modules.len();
            }
            return i;
        }
    }
    uint idx = (uint)mod.req_modules.len();
    mod.req_modules.push({ specifier, null, attr_type, false, deferred, idx });
    return idx;
}

// Register an import entry in the module.
fn void mod_register_import(CompModuleDef* mod, char[] local_name, char[] import_name, uint req_idx, bool is_star, bool is_default, bool is_deferred = false, bool is_source = false) {
    mod.imports.push({ local_name, import_name, req_idx, is_star, is_default, is_deferred, is_source });
}

// True when `export_name` is already an ExportedName of this module.
//
// ES2024 §16.2.3.1: "It is a Syntax Error if the ExportedNames of ModuleItemList
// contains any duplicate entries." Every named export funnels through
// mod_register_export, so testing here catches all the spellings that can
// collide -- `export {x}` twice, two `as z` aliases, an `export default` paired
// with `{y as default}`, two same-named `export function` declarations, and
// `export * as z` against a local `{x as z}`.
//
// `export * from` is exempt: it contributes no ExportedName of its own (a name
// it would have re-exported is instead dropped when ambiguous), which is why
// star exports are registered through mod_register_star_export and never
// reach this path.
fn bool mod_has_export_name(CompModuleDef* mod, char[] export_name) {
    for (uint i = 0; i < (uint)mod.exports.len(); i++) {
        if (str_eq(mod.exports[i].export_name, export_name)) return true;
    }
    return false;
}

// Register a named export, rejecting a duplicate ExportedName (§16.2.3.1).
//
// Wraps mod_register_export at the one point every named export passes
// through, so the duplicate rule cannot be missed by a new export form:
// mod_register_export itself is a plain function with no compiler context to
// raise a SyntaxError from.
fn void? CompilerContext.register_export(&self, CompModuleDef* mod, char[] local_name,
    char[] export_name, bool is_indirect, uint req_idx, bool is_lexical = false,
    bool declares_binding = false)
{
    if (mod_has_export_name(mod, export_name)) {
        return self.fail("duplicate export name")~;
    }
    mod_register_export(mod, local_name, export_name, is_indirect, req_idx, is_lexical,
                        declares_binding);
}

// Register an export entry in the module.
fn void mod_register_export(CompModuleDef* mod, char[] local_name, char[] export_name, bool is_indirect, uint req_idx, bool is_lexical = false, bool declares_binding = false) {
    mod.exports.push({ local_name, export_name, is_indirect, req_idx, is_lexical, declares_binding });
}

// Find the ImportEntry (if any) whose local binding name is `local_name`.
// Used by `export { x }` (no `from` clause) to implement ECMA-262
// §16.2.1.7.1 ParseModule step 10.1: an export whose LocalName matches an
// already-imported binding is NOT a local export, it becomes an indirect
// re-export sourced from the ImportEntry's own module/import name, per
// Table 59. Returns null when `local_name` names an ordinary local binding.
fn CompImportEntry* mod_find_import_by_local(CompModuleDef* mod, char[] local_name) {
    for (uint i = 0; i < (uint)mod.imports.len(); i++) {
        if (str_eq(mod.imports[i].local_name, local_name)) return &mod.imports[i];
    }
    return null;
}

// Register a star export entry in the module.
fn void mod_register_star_export(CompModuleDef* mod, uint req_idx) {
    mod.star_exports.push({ req_idx });
}

// Check whether a name may not appear in a binding position. The `strict`,
// `in_async_or_module` and `in_generator_or_blocked_yield` parameters are the
// grammar parameters the caller's position fixes; the defaults describe a
// strict, non-async, non-generator position. Rejected:
//   - `eval`, `arguments`, in strict code only (§11.6.2.2, §13.1.1).
//   - `null`, `true`, `false`, NullLiteral / BooleanLiteral sources, in every
//     mode; never valid as an IdentifierName in binding position. Lexed as
//     IDENTIFIER with `str_value` matching the literal name (no dedicated
//     token type in this engine), so a post-advance check is the only way to
//     catch `var true = 1` while still allowing property access `obj.true`
//     etc.
//   - `let`, `static`, and the other strict-mode reserved words, in strict
//     code only.
//   - `yield` per in_generator_or_blocked_yield and `await` per
//     in_async_or_module; callers that know the position is outside the
//     reservation scope pass false, because the lexer still returns the
//     keyword token there and the parser accepts it as a name.
fn bool is_restricted_name(char[] name,
                           bool in_async_or_module = true,
                           bool in_generator_or_blocked_yield = true,
                           bool strict = true) @inline {
    switch (name.len) {
        case 3:
            // "let"
            if (name[0] == 'l' && name[1] == 'e' && name[2] == 't') return strict;
            break;
        case 4:
            // "eval", "null", "true". `null`/`true` are ReservedWords in ALL
            // code; `eval` is only a restricted binding target in strict code
            // (ES2024 §13.1.1), which is what `Function('var eval;')` relies on.
            if (name[0] == 'e' && name[1] == 'v' && name[2] == 'a' && name[3] == 'l') return strict;
            if (name[0] == 'n' && name[1] == 'u' && name[2] == 'l' && name[3] == 'l') return true;
            if (name[0] == 't' && name[1] == 'r' && name[2] == 'u' && name[3] == 'e') return true;
            break;
        case 5:
            // "await", "false", "yield"
            // await is reserved only inside an async function/arrow/method, a
            // module, or a class static block ([Await] grammar parameter);
            // outside those scopes it is a plain IdentifierName and may appear
            // as an assignment target. Same shape for yield, with [Yield]
            // scoping. Pass false from callers that know the context is
            // outside the reservation scope (assignment LHS, destructuring).
            if (name[0] == 'a' && name[1] == 'w' && name[2] == 'a' &&
                name[3] == 'i' && name[4] == 't') return in_async_or_module;
            if (name[0] == 'f' && name[1] == 'a' && name[2] == 'l' &&
                name[3] == 's' && name[4] == 'e') return true;
            if (name[0] == 'y' && name[1] == 'i' && name[2] == 'e' &&
                name[3] == 'l' && name[4] == 'd') return in_generator_or_blocked_yield;
            break;
        case 6:
            // "static", "public"
            if (name[0] == 's' && name[1] == 't' && name[2] == 'a' &&
                name[3] == 't' && name[4] == 'i' && name[5] == 'c') return strict;
            if (name[0] == 'p' && name[1] == 'u' && name[2] == 'b' &&
                name[3] == 'l' && name[4] == 'i' && name[5] == 'c') return strict;
            break;
        case 7:
            // "package", "private"
            if (name[0] == 'p' && name[1] == 'a' && name[2] == 'c' &&
                name[3] == 'k' && name[4] == 'a' && name[5] == 'g' &&
                name[6] == 'e') return strict;
            if (name[0] == 'p' && name[1] == 'r' && name[2] == 'i' &&
                name[3] == 'v' && name[4] == 'a' && name[5] == 't' &&
                name[6] == 'e') return strict;
            break;
        case 9:
            // "arguments", "interface"
            if (name[0] == 'a' && name[1] == 'r' && name[2] == 'g' &&
                name[3] == 'u' && name[4] == 'm' && name[5] == 'e' &&
                name[6] == 'n' && name[7] == 't' && name[8] == 's') return strict;
            if (name[0] == 'i' && name[1] == 'n' && name[2] == 't' &&
                name[3] == 'e' && name[4] == 'r' && name[5] == 'f' &&
                name[6] == 'a' && name[7] == 'c' && name[8] == 'e') return strict;
            break;
        case 10:
            // "implements"
            if (name[0] == 'i' && name[1] == 'm' && name[2] == 'p' &&
                name[3] == 'l' && name[4] == 'e' && name[5] == 'm' &&
                name[6] == 'e' && name[7] == 'n' && name[8] == 't' &&
                name[9] == 's') return strict;
            break;
    }
    // "protected"
    if (name.len == 9 && name[0] == 'p' && name[1] == 'r' && name[2] == 'o' &&
        name[3] == 't' && name[4] == 'e' && name[5] == 'c' && name[6] == 't' &&
        name[7] == 'e' && name[8] == 'd') {
        return strict;
    }
    return false;
}

// Emit the environment store for a declared variable (PUTVAR or PUTLEX/PUTLEX_C).
fn void CompilerContext.emit_var_store(&self, ushort reg, uint name_idx, bool is_lexical, bool is_const, bool walk_chain = false) {
    if (is_lexical) {
        if (is_const) {
            self.emit_a_bc(Opcode.PUTLEX_C, (uint)reg, name_idx);
        } else {
            self.emit_a_bc(Opcode.PUTLEX, (uint)reg, name_idx);
        }
        // The PUTLEX/PUTLEX_C above publishes the binding's initial value to
        // the lex_env and replaces the INITTZ sentinel, the TDZ period ends
        // here.  Clear `is_tdz` on the inner-most matching scope_stack entry
        // so subsequent reads inside the same scope can use the fast register
        // path again.
        if (name_idx < self.const_count) {
            HString* hs = (HString*)self.constants[name_idx].get_heapptr();
            if (hs != null) {
                char[] bname = hs.get_data();
                for (uint i = self.scope_depth; i > 0; i--) {
                    uint idx = i - 1;
                    if (self.scope_stack[idx].kind == SCOPEMARK) continue;
                    if (str_eq(self.scope_stack[idx].name, bname)) {
                        self.scope_stack[idx].is_tdz = false;
                        break;
                    }
                }
            }
        }
    } else if (walk_chain) {
        // DECLVAR writes to the immediate var_env only, which is wrong when the
        // binding lives in an outer env: a sloppy catch body reusing the catch
        // parameter's binding (B.3.5: same name on a BindingIdentifier catch
        // parameter and a body `var`) is in the catch's lex_env, and a `with`
        // body hoists to the with-object. PUTVAR walks the chain and updates
        // the existing binding instead of creating a shadow in var_env.
        self.emit_a_bc(Opcode.PUTVAR, (uint)reg, name_idx);
    } else {
        // DECLVAR declares the binding in the immediate var_env (function-scoped).
        // PUTVAR (plain assignment) walks the chain to update existing bindings.
        self.emit_a_bc(Opcode.DECLVAR, (uint)reg, name_idx);
    }
}

struct SwitchClause {
    uint body_addr;
    uint ft_jump_addr;   // fall-through JUMP at the end of the body, patched to the next body
}

struct PerIterBinding {
    uint name_idx;
    bool is_const;
}

alias PerIterBindings = List{PerIterBinding};

// Copy a classic for-loop's lexical head bindings into a fresh environment
// (ES2015 §14.7.4.9 CreatePerIterationEnvironment).  All values must be read
// before the old environment is popped: after the pop, later bindings in a
// multi-declarator head are unreachable.
fn void CompilerContext.emit_create_per_iteration_env(&self, PerIterBinding[] bindings)
{
    List{ushort} temps;
    temps.init(mem, bindings.len);
    defer temps.free();
    foreach (b : bindings) {
        ushort reg = self.alloc_reg();
        temps.push(reg);
        self.emit_a_bc(Opcode.GETVAR, (uint)reg, b.name_idx);
    }
    self.emit_simple(Opcode.POP_LEX);
    self.emit_simple(Opcode.PUSH_LEX);
    foreach (i, b : bindings) {
        Opcode store_op = b.is_const ? Opcode.PUTLEX_C : Opcode.PUTLEX;
        self.emit_a_bc(store_op, (uint)temps[i], b.name_idx);
    }
    foreach_r (reg : temps.array_view()) self.free_reg(reg);
}

// Iterator record produced by emit_iter_open and threaded through the loop.
struct IterRec {
    ushort method_reg;  // the iterator object (also the ITER_CLOSE target)
    ushort next_reg;    // its .next method
    ushort callee_reg;  // per-iteration callee slot (reloaded each step)
    ushort callee_this_reg;
    bool   is_await;
    // Address of the fused fast path's done-branch, valid while
    // has_fast_exit. Lives here rather than on the context because for-of
    // loops nest: a shared field would be overwritten by the inner loop and
    // the outer branch would never be patched, leaving it jumping to offset
    // zero -- an infinite loop.
    uint   fast_exit;
    bool   has_fast_exit;
}

// GetIterator(src, hint): look up the iterator method, call it, fetch .next.
// For sync (hint=sync) this is Symbol.iterator. For async (hint=async,
// for-await) this is GET_ITER_ASYNC, which does the spec GetIterator(obj,async):
// prefer Symbol.asyncIterator; if absent, wrap Symbol.iterator() in an
// %AsyncFromSyncIterator% adapter so a plain sync iterable (array, generator)
// works under `for await`. Either way the iterator lands in method_reg (below
// the callee window) and .next in next_reg, with the callee/this window ABOVE
// them, so a generator source overlaying the sliding window on resume cannot
// clobber them (see plan 042/043).
fn IterRec? CompilerContext.emit_iter_open(&self, ushort src_reg, bool is_await) {
    // The CALL below takes its callee from method_reg and its receiver from
    // the register after it, so method_reg is allocated last.
    ushort next_reg = self.alloc_reg();
    ushort method_reg = self.alloc_reg();
    uint open_done_jump = 0;
    if (is_await) {
        // GET_ITER_ASYNC A, B: A ← GetIterator(reg B, async). Handles the
        // @@asyncIterator lookup + AsyncFromSync wrapping in one VM step, so the
        // iterator object lands directly in method_reg (allocated first → below
        // the callee window, same invariant as the sync path's CALL result).
        self.emit_abc(Opcode.GET_ITER_ASYNC, (uint)method_reg, (uint)src_reg, 0);
    } else {
        // A null/undefined source is not iterable; reject it before the
        // @@iterator read, which would otherwise fail as a property access.
        self.emit_abc(Opcode.CHKITER, (uint)src_reg, 0, 1);

        // Fused open for a plain array, which refuses into the generic
        // sequence below; a success jumps past it with the iterator and its
        // .next already in place.
        self.emit_abc(Opcode.ITER_OPEN_FAST, (uint)method_reg, (uint)src_reg, (uint)next_reg);
        uint open_slow_jump = self.emit_jump(Opcode.JUMP);
        open_done_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(open_slow_jump);

        ushort sym_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.GETVAR, (uint)sym_reg, self.add_string_constant("Symbol"));
        ushort iter_key_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDCONST, (uint)iter_key_reg, self.add_string_constant("iterator"), 0);
        ushort symbol_val_reg = self.alloc_reg();
        self.emit_abc(Opcode.GETPROP, (uint)symbol_val_reg, (uint)sym_reg, (uint)iter_key_reg);
        self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)src_reg, (uint)symbol_val_reg);
        self.free_reg(symbol_val_reg);
        self.free_reg(iter_key_reg);
        self.free_reg(sym_reg);

        // GetIterator step 3, before the call: a non-callable @@iterator must
        // report that the source is not iterable, not that undefined is not a
        // function (which the bare CALL below would say).
        self.emit_abc(Opcode.CHKITER, (uint)method_reg, (uint)src_reg, 0);

        ushort this_slot = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)this_slot, (uint)src_reg, 0);
        self.emit_abc(Opcode.CALL, (uint)method_reg, (uint)method_reg, 0);
        self.free_reg(this_slot);

        // GetIterator step 5: the iterator the method returned must be an
        // Object, checked before the `.next` read below.
        self.emit_abc(Opcode.CHKITER, (uint)method_reg, 0, 2);
    }

    ushort next_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)next_key_reg, self.add_string_constant("next"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)next_reg, (uint)method_reg, (uint)next_key_reg);
    self.free_reg(next_key_reg);
    if (!is_await) self.patch_jump(open_done_jump);

    IterRec rec;
    rec.method_reg = method_reg;
    rec.next_reg = next_reg;
    rec.callee_reg = self.alloc_reg();
    rec.callee_this_reg = self.alloc_reg();
    rec.is_await = is_await;
    return rec;
}

// One iteration step: reload callee/this (healing a generator source that
// overwrote the callee window last iteration), call .next(), require an object
// result, unpack .done/.value. Writes the value into val_slot (which the caller
// allocated below the callee window) and returns the exit jump to patch at the
// done=true target. Leaves no live temps above val_slot.
fn uint? CompilerContext.emit_iter_step(&self, IterRec rec, ushort val_slot, uint* out_fast_exit) {
    // Fused fast step for a built-in array iterator, laid out as the opcode
    // documents: refusal falls through to the first JUMP (into the generic
    // sequence below), a finished iteration takes the second, and a produced
    // value lands past both. for-await is excluded because its step has to
    // await the promise .next() returns.
    uint fast_done_jump = 0;
    uint fast_cont_jump = 0;
    bool has_fast = false;
    *out_fast_exit = 0;
    if (!rec.is_await) {
        self.emit_abc(Opcode.ITER_NEXT_FAST, (uint)val_slot, (uint)rec.method_reg, (uint)rec.next_reg);
        // Layout the handler relies on, in the order it branches to them:
        //   +0  JUMP -> the generic sequence (refusal falls through to here)
        //   +1  JUMP -> the loop exit        (handled, iteration finished)
        //   +2  JUMP -> the loop body        (handled, value produced)
        // The third is needed because the generic sequence sits between this
        // point and the body: landing "past the JUMPs" would land on the slow
        // path, not on the consumer of the value.
        uint to_slow = self.emit_jump(Opcode.JUMP);
        fast_done_jump = self.emit_jump(Opcode.JUMP);
        fast_cont_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(to_slow);
        has_fast = true;
    }

    self.emit_abc(Opcode.LDREG, (uint)rec.callee_reg, (uint)rec.next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)rec.callee_this_reg, (uint)rec.method_reg, 0);

    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)rec.callee_reg, 0);

    // for-await (§14.7.5.6): the async .next() returns a Promise of the
    // IteratorResult, await it, then treat the settled value as the result.
    // GET_ITER_ASYNC guarantees a genuine async iterator (sync sources are
    // adapter-wrapped, and the adapter awaits the value internally), so a single
    // await here suffices; the settled result is a plain {value, done} object.
    if (rec.is_await) {
        self.emit_abc(Opcode.AWAIT, (uint)result_reg, 0, 0);
        self.emit_abc(Opcode.LOAD_RESUME, (uint)result_reg, 0, 0);
    }

    // ES2022 §14.7.5.6 step 3.b: the .next() result must be an Object.
    self.emit_abc(Opcode.CHKOBJ, (uint)result_reg, 0, 0);

    ushort done_key_reg = self.alloc_reg();
    ushort done_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)done_key_reg, self.add_string_constant("done"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)done_key_reg);
    uint exit_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

    ushort value_key_reg = self.alloc_reg();
    ushort val_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)value_key_reg, self.add_string_constant("value"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)val_reg, (uint)result_reg, (uint)value_key_reg);

    // Move the value below the callee window, then release the above-window
    // protocol temps so the per-value consumer (which may run a nested iterator
    // protocol for destructuring) does not overlap the outer call frame.
    self.emit_abc(Opcode.LDREG, (uint)val_slot, (uint)val_reg, 0);
    self.free_reg(val_reg);
    self.free_reg(value_key_reg);
    self.free_reg(done_reg);
    self.free_reg(done_key_reg);
    self.free_reg(result_reg);

    // Both the fast path's done-branch and the generic path's done-branch have
    // to reach the same loop exit. Chain the fast one onto the generic one so
    // the single returned jump still describes the exit for the caller to
    // patch; the fast branch lands on the generic branch, which then jumps on.
    if (has_fast) {
        // The continue-branch lands here, where the generic path arrives once
        // it has stored the value. The done-branch cannot be aimed at the
        // generic done-branch itself -- that is an IF_TRUE reading a register
        // only the generic path fills -- so it is returned to the caller
        // alongside exit_jump and patched to the same loop exit.
        self.patch_jump(fast_cont_jump);
        *out_fast_exit = fast_done_jump;
    }

    return exit_jump;
}

// IteratorClose on the loop iterator. throw_variant=true suppresses errors from
// .return access/call (the original throw takes precedence, §7.4.6 steps 6,8).
// For for-await this is AsyncIteratorClose (§7.4.11): the .return() result is
// awaited before the completion propagates.
fn void CompilerContext.emit_iter_close(&self, IterRec rec, bool throw_variant) {
    if (rec.is_await) {
        // ITER_CLOSE_ASYNC leaves the .return() result in method_reg (or
        // undefined when there is nothing to close) and reports whether a
        // real result needs awaiting in did_await_reg. §7.4.11 only calls
        // Await when .return() was actually invoked, unlike a real user
        // `await`, AWAIT always costs a microtask tick now, so the no-close
        // case must skip it entirely rather than "awaiting undefined".
        ushort did_await_reg = self.alloc_reg();
        self.emit_abc(Opcode.ITER_CLOSE_ASYNC, (uint)rec.method_reg, throw_variant ? 1 : 0, (uint)did_await_reg);
        uint skip_await = self.emit_cond_jump(Opcode.IF_FALSE, (uint)did_await_reg);
        self.emit_abc(Opcode.AWAIT, (uint)rec.method_reg, 0, 0);
        self.emit_abc(Opcode.LOAD_RESUME, (uint)rec.method_reg, 0, 0);
        self.patch_jump(skip_await);
        self.free_reg(did_await_reg);
        return;
    }
    self.emit_abc(Opcode.ITER_CLOSE, (uint)rec.method_reg, throw_variant ? 1 : 0, 0);
}

// Free the four iterator-record registers (reverse allocation order).
fn void CompilerContext.free_iter_rec(&self, IterRec rec) {
    self.free_reg(rec.callee_this_reg);
    self.free_reg(rec.callee_reg);
    self.free_reg(rec.next_reg);
    self.free_reg(rec.method_reg);
}

// The single for-of loop skeleton. The RHS has already been evaluated into
// src_reg; head describes the per-iteration value binding. On entry the loop
// variable / pattern (per head) is already declared in the current scope.
// Emits the full ForIn/OfBodyEvaluation loop (§14.7.5.6): GetIterator → loop
// { per-iter env, .next, done? exit, bind, body } → IteratorClose. Frees
// src_reg and restores scope/regs to saved_scope/saved_reg on exit.
fn void? CompilerContext.emit_forof(&self, ForOfHead head, ushort src_reg, uint saved_scope, ushort saved_reg, bool is_await, uint ast_body = 0) {
    IterRec rec = self.emit_iter_open(src_reg, is_await)!;

    // Value lives below the callee window for the whole loop, so a nested
    // iterator protocol (destructuring) never overlaps the outer call frame.
    ushort val_slot = self.alloc_persistent_reg();

    // ES §14.7.5.6: V starts as undefined; reset the eval accumulator so a
    // zero-iteration loop yields undefined (identifier form, eval mode only).
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }

    // A lexical head needs a declarative environment for two separate reasons,
    // and they have different costs:
    //
    //  1. Scoping. `let`/`const` head bindings are block-scoped to the loop, so
    //     they must not survive into the enclosing scope. One env for the whole
    //     loop is enough for that.
    //  2. Per-iteration freshness (§14.7.5.6 CreatePerIterationEnvironment).
    //     Only observable through something that outlives its iteration -- a
    //     closure, `eval`, a direct capture -- and that needs a *new* env every
    //     step, which is an allocation per element.
    //
    // So an uncaptured head still gets an env, just hoisted out of the loop:
    // correct scoping at one allocation per loop instead of one per element.
    // This mirrors the capture gate the C-style `for` already applies to its own
    // CreatePerIterationEnvironment. capture_all degrades to captured through
    // is_captured_name, so a scanner that lost track keeps the old behaviour.
    bool needs_lex_env = head.is_lexical && !head.id_is_bare;
    bool needs_per_iter_env = needs_lex_env && self.forof_head_is_captured(head);
    bool needs_hoisted_env = needs_lex_env && !needs_per_iter_env;

    if (needs_hoisted_env) {
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
        self.emit_head_inittz(head);
    }

    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);
    self.innermost_loop().iter_close_reg = (int)rec.method_reg;
    self.innermost_loop().is_await_loop = is_await;

    if (needs_per_iter_env) {
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
        self.emit_head_inittz(head);
    }

    uint fast_exit = 0;
    uint exit_jump = self.emit_iter_step(rec, val_slot, &fast_exit)!;

    // IteratorClose-on-throw guard (§14.7.5.6): wrapping the bind and body means
    // any abrupt completion closes the iterator before propagating.
    uint iter_try_addr  = self.emit_a_bc(Opcode.TRY, 0, 0);
    uint iter_jump_slot = self.emit_a_bc(Opcode.NOP, 0, 0);

    self.emit_head_bind(head, val_slot)!;

    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }
    // The head's `)` closes the for-of clause, not an operand, so a following
    // `/` must start a RegularExpressionLiteral (B2).
    self.gen_stmt(ast_body)!;
    self.gen_line_end(ast_body);

    self.emit_simple(Opcode.ENDTRY);
    uint jump_over = self.emit_jump(Opcode.JUMP);

    uint catch_target = self.code_count;
    ushort err_reg = self.alloc_reg();
    self.emit_abc(Opcode.CATCH, (uint)err_reg, 0, 0);
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.POP_LEX);
    }
    self.emit_iter_close(rec, true);
    self.emit_abc(Opcode.THROW, (uint)err_reg, 0, 0);
    self.free_reg(err_reg);

    self.patch_jump(jump_over);
    uint catch_off = catch_target - iter_try_addr;
    self.code[iter_try_addr] = bytecode::make_a_bc(Opcode.TRY, 1, catch_off);
    self.code[iter_jump_slot] = bytecode::make_a_bc(Opcode.NOP, 0, 0);

    // Normal-path per-iter env epilogue (continue already popped its own env
    // back to the loop level, so it lands on the back-jump, not here).
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.POP_LEX);
    }

    self.innermost_loop().continue_target = self.code_count;
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    // Exit path (done=true): pop the per-iter env. Per ES2022 §14.7.5.7
    // ForIn/OfBodyEvaluation, a `nextResult.[[Done]]` of true ends the loop
    // with a normal completion directly, IteratorClose/AsyncIteratorClose
    // is only invoked for an abrupt completion out of the loop (break,
    // throw, or a `return` inside the body), never on natural exhaustion.
    self.patch_jump(exit_jump);
    // The fused fast path's done-branch exits the loop at the same point.
    if (fast_exit != 0) { self.patch_jump(fast_exit); }
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    self.pop_loop();

    // The hoisted env wraps the whole loop, so it pops once here -- after
    // pop_loop, since `break` unwinds only to the loop's saved_lex_depth (taken
    // before this env was pushed) and so lands with it still standing.
    if (needs_hoisted_env) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }

    self.free_reg(val_slot);
    self.free_iter_rec(rec);
    self.free_reg(src_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

// True when a lexical for-of head needs a real per-iteration environment.
//
// §14.7.5.6 creates a fresh binding every iteration, but the freshness is only
// observable through something that holds on to the binding past its iteration:
// a closure, `eval`, or a direct capture. When no name in the head is captured,
// every iteration's binding is written and read within that one iteration, so a
// single reused register is indistinguishable from a fresh env -- and skips a
// heap allocation per element.
//
// This mirrors the gate the C-style `for` loop already applies to its own
// CreatePerIterationEnvironment (see needs_periterenv above); for-of simply
// never had it. capture_all degrades to true through is_captured_name, so a
// scanner that lost track keeps the conservative behaviour.
fn bool CompilerContext.forof_head_is_captured(&self, ForOfHead head) {
    switch (head.kind) {
        case IDENT:
            HString* hs = (HString*)self.constants[head.id_name_idx].get_heapptr();
            return self.is_captured_name(hs.get_data());
        case DESTRUCTURE:
            // Any captured leaf forces the env for the whole head: the binds
            // share one iteration, so they share its lifetime.
            foreach (&b : head.binds) {
                if (!b.is_synthetic && self.is_captured_name(self.bind_name(b))) return true;
            }
            return false;
        case MEMBER:
            // No head bindings, so nothing to keep fresh.
            return false;
    }
}

// Per-iteration TDZ init for lexical head bindings (fresh env each iteration).
fn void CompilerContext.emit_head_inittz(&self, ForOfHead head) {
    switch (head.kind) {
        case IDENT:
            self.emit_a_bc(Opcode.INITTZ, 0, head.id_name_idx);
        case DESTRUCTURE:
            foreach (&b : head.binds) {
                if (!b.is_synthetic) self.emit_a_bc(Opcode.INITTZ, 0, b.name_idx);
            }
        case MEMBER:
            // no head bindings
    }
}

// The per-value step: bind val_slot to the loop target (§14.7.5.6). Runs inside
// the IteratorClose-on-throw guard.
fn void? CompilerContext.emit_head_bind(&self, ForOfHead head, ushort val_slot) {
    switch (head.kind) {
        case IDENT:
            if (head.id_is_bare && head.id_reg_resident) {
                // Register-cached local target: write straight into its home
                // register (id_reg). No PUTVAR, that would update only the env
                // slot and then clear the source reg, leaving the body's register
                // read of the local stale (bare-forof var-desync fix). Matches how
                // a plain `b = val` assignment to a register-resident local emits.
                self.emit_abc(Opcode.LDREG, (uint)head.id_reg, (uint)val_slot, 0);
            } else if (head.id_is_bare) {
                // Env-resident bare target: stage in id_reg, then store to the env.
                // PUTVAR_ASSIGN, not PUTVAR: the head is an assignment position, so
                // an undeclared target follows PutValue (ReferenceError in strict
                // code, an implicit global in sloppy) and const/TDZ throws too.
                self.emit_abc(Opcode.LDREG, (uint)head.id_reg, (uint)val_slot, 0);
                self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)head.id_reg, head.id_name_idx);
            } else {
                self.emit_abc(Opcode.LDREG, (uint)head.id_reg, (uint)val_slot, 0);
                // B.3.5 reuse of the catch parameter: PUTVAR walks the chain so
                // the catch's lex_env binding is the one updated, not a fresh
                // shadow created in var_env.
                self.emit_var_store(head.id_reg, head.id_name_idx, head.is_lexical, head.is_const,
                    head.id_walk_chain);
            }
        case DESTRUCTURE:
            self.emit_destructure(head.binds, head.is_object_pattern, val_slot, head.store_mode,
                                  head.is_lexical, head.is_const)!;
        case MEMBER:
            self.gen_member_bind(head.ast_target, val_slot)!;
    }
}

// Emit the non-throw IteratorClose for the loop at loop_stack[li] during an
// abrupt-exit unwind (break/return/labeled break). For a for-await loop this is
// AsyncIteratorClose (§7.4.11): the .return() result must be awaited. Clobbering
// the iterator register with the awaited result is safe here, the loop is being
// abandoned. Assumes loop_stack[li].iter_close_reg >= 0.
// How many try regions an unwind IteratorClose for loop_stack[li] is escaping:
// every `try` entered between the loop header and this jump site. §7.4.9 runs
// IteratorClose only after the abrupt completion is established, so a throw
// from `.return()` must not be caught by any of them (ITER_CLOSE_ESCAPE).
fn uint CompilerContext.iter_close_catcher_skip(&self, uint li) {
    uint entered = self.loop_stack[li].saved_try_depth;
    return self.try_depth > entered ? self.try_depth - entered : 0;
}

fn void CompilerContext.emit_unwind_iter_close(&self, uint li) {
    uint reg = (uint)self.loop_stack[li].iter_close_reg;
    uint skip = self.iter_close_catcher_skip(li);
    // Pop the loop body's IteratorClose-on-throw catcher (the TRY emitted
    // around bind+body). Jumping out of the body bypasses its ENDTRY, which
    // left that catcher on act.cat: harmless where the next pop happens to
    // belong to it, but an ENDFINALLY reached afterwards then pops the stale
    // for-of catcher instead of the finally's own and drops the completion it
    // was carrying -- `try { throw e } finally { for (v of it) break; }` lost
    // `e` entirely.
    // With no user try in between, a plain ENDTRY retires the for-of guard.
    // Otherwise ENDTRY would pop that user catcher instead, so ITER_CLOSE_ESCAPE
    // does both jobs: disarm the catch clauses of the regions being escaped
    // (§7.4.9 -- their finally blocks stay armed) and retire the guard beneath.
    if (skip == 0) {
        self.emit_simple(Opcode.ENDTRY);
    } else {
        self.emit_abc(Opcode.ITER_CLOSE_ESCAPE, skip, reg, 0);
    }
    if (self.loop_stack[li].is_await_loop) {
        // Operand C names the register that reports whether `.return()` produced a result to await.
        ushort did_await_reg = self.alloc_reg();
        self.emit_abc(Opcode.ITER_CLOSE_ASYNC, reg, 0, (uint)did_await_reg);
        uint skip_await = self.emit_cond_jump(Opcode.IF_FALSE, (uint)did_await_reg);
        self.emit_abc(Opcode.AWAIT, reg, 0, 0);
        self.emit_abc(Opcode.LOAD_RESUME, reg, 0, 0);
        self.patch_jump(skip_await);
        self.free_reg(did_await_reg);
    } else {
        self.emit_abc(Opcode.ITER_CLOSE, reg, 0, 0);
    }
}

// Emit ITER_CLOSE for every enclosing for-of loop, innermost first.
// A return exits all loops in the function, so each loop's iterator must be
// closed (§14.7.5.7, abrupt loop completions call IteratorClose).
fn void CompilerContext.emit_return_iter_closes(&self) {
    for (int li = (int)self.loop_depth() - 1; li >= 0; li--) {
        if (self.loop_stack[li].iter_close_reg >= 0) {
            self.emit_unwind_iter_close((uint)li);
        }
    }
}

// Get the CompModuleDef* from the opaque current_module pointer.
// Returns null if not in module mode.
fn CompModuleDef* CompilerContext.get_module_def(&self) {
    return (CompModuleDef*)self.current_module;
}
