module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;


// ============================================================================
// Private class members: name resolution
//
// Each private name (`#foo`) declared in a class body gets a compiler-managed
// lexical variable in the scope enclosing the class (declared the same way
// as `__super__`, see class.c3), holding the per-evaluation runtime hidden
// symbol. A stack of PrivateNameEntry records, scoped by class nesting,
// backs `resolve_private_name`; there is no get-or-create, so a reference to
// an undeclared name is a compile-time SyntaxError.
// ============================================================================

// The class id for slot binding names is a monotonic counter on the heap,
// shared by all compiler contexts of one runtime so that sibling classes get
// distinct ids. Per-evaluation freshness comes from NEW_PRIV_SYM at runtime.

// Build the lexical binding name for a private slot into `buf`, which must
// hold PRIVATE_SLOT_PREFIX_MAX + name.len bytes: "#priv:<id>:<name>".
// Returns the filled prefix of `buf`.
const usz PRIVATE_SLOT_PREFIX_MAX = 17; // "#priv:", ten digits, ':'
fn char[] format_private_slot_name(char[] buf, uint class_id, char[] name) {
    char[] prefix = "#priv:";
    usz pos = 0;
    for (usz i = 0; i < prefix.len && pos < buf.len; i++) buf[pos++] = prefix[i];
    char[12] digits;
    usz dcount = 0;
    do {
        digits[dcount++] = (char)('0' + class_id % 10);
        class_id /= 10;
    } while (class_id > 0);
    while (dcount > 0 && pos < buf.len) buf[pos++] = digits[--dcount];
    if (pos < buf.len) buf[pos++] = ':';
    for (usz i = 0; i < name.len && pos < buf.len; i++) buf[pos++] = name[i];
    return buf[:pos];
}

// Build and intern the slot binding name for `name` in class `class_id`.
fn char[] CompilerContext.private_slot_name(&self, uint class_id, char[] name) {
    char[] buf = self.lexer.arena_alloc(PRIVATE_SLOT_PREFIX_MAX + name.len);
    return self.intern_slot_name(format_private_slot_name(buf, class_id, name));
}

// Canonical CESU-8 text of a slot binding name, for storage in PrivateNameEntry,
// module metadata and declare_priv_slot. The bytes live in the lexer arena, so
// they last as long as the compilation; module metadata copies them out in
// `retain_names`. Two spellings of one name, such as an astral character typed
// raw and the same character as a surrogate pair, produce the same bytes.
fn char[] CompilerContext.intern_slot_name(&self, char[] slot_name) {
    usz len = hstring::canonical_cesu8(slot_name, null);
    if (len == 0) return "";
    char[] stable = self.lexer.arena_alloc(len);
    if (stable.len != len) return slot_name;
    hstring::canonical_cesu8(slot_name, stable.ptr);
    return stable;
}

// Declare a private-name slot binding (`#priv:<id>:name`, `#priv:<id>:brand`
// or `#priv:<id>:sbrand`) in the class-enclosing context. It allocates no
// register and pushes nothing to scope_stack. Slots are only read by name
// (GETVAR) from method and field-init bodies. A register per slot would
// exhaust the 512-register limit for classes with 500+ private names, as the
// test262 start-unicode-* suites do.
//
// The class's lex env is still required, since PUTLEX stores each fresh
// NEW_PRIV_SYM there. So this marks has_lexical_bindings, which keeps PUSH_LEX.
fn void CompilerContext.declare_priv_slot(&self, char[] name) {
    // Mark the enclosing scope as having lexical bindings, required so the
    // class's PUSH_LEX is emitted and the env elision gate (has_closures &&
    // has_lexical_bindings) keeps the env alive.
    self.has_lexical_bindings = true;
}

// Push a fresh private-name scope for a class body about to be parsed.
fn void CompilerContext.push_private_scope(&self) {
    Heap* hp = (Heap*)self.heap;
    self.private_name_table.scopes.push({ self.private_name_table.count, hp.priv_class_id++ });
}

// Pop the innermost private-name scope, discarding names declared inside it.
fn void CompilerContext.pop_private_scope(&self) {
    if (try scope = self.private_name_table.scopes.pop()) {
        self.private_name_table.count = scope.start;
    }
}

// The innermost open class body, or a zero scope (start 0, class id 0) when
// none is open, as in an eval that inherited its caller's names.
fn PrivateScope CompilerContext.innermost_private_scope(&self) {
    return self.private_name_table.scopes.last() ?? {};
}

// Declare a private name in the innermost (current) class scope.  Returns
// a pointer to the new entry, or a fault on duplicate declaration (the
// caller reports the SyntaxError) or table overflow.
//
// Duplicates are checked within the current class body only. An inner class
// may redeclare an outer `#x`, as each class has its own PrivateEnvironment.
fn PrivateNameEntry*? CompilerContext.declare_private_name(&self, char[] name) {
    // Intern first. str_intern rewrites astral UTF-8 into CESU-8, so a literal
    // and a \u{...} spelling of the same name only match once both are interned.
    // Every entry's `.name` is interned, so duplicate checks must compare
    // interned forms.
    char[] stable_name = self.intern_slot_name(name);
    PrivateNameTable* t = self.private_name_table;
    uint scope_begin = self.innermost_private_scope().start;
    for (uint i = scope_begin; i < t.count; i++) {
        if (str_eq(t.entries[i].name, stable_name)) {
            return COMPILE_ERROR~;  // duplicate declaration
        }
    }
    self.ensure_private_name_cap();
    if (t.count >= t.cap) {
        return COMPILE_ERROR~;
    }
    uint idx = t.count;
    // `stable_name` points at interned HString data, which settles the form
    // problem above for decoded and source-slice names alike.
    t.entries[idx].name = stable_name;
    t.entries[idx].is_method = false;
    t.entries[idx].has_getter = false;
    t.entries[idx].has_setter = false;

    // Lexical name such as "#priv:3:foo". A '#' cannot start a source
    // identifier, so user code cannot collide with it. The slice is interned
    // because the lex-binding tracker and PrivateNameEntry keep it.
    uint class_id = self.innermost_private_scope().class_id;
    char[] slot_name = self.private_slot_name(class_id, stable_name);

    self.declare_priv_slot(slot_name);
    t.entries[idx].slot_name = slot_name;

    t.count++;
    return &t.entries[idx];
}

// Declare the class brand (one per class body that has any private member).
// Uses a source-illegal name ("#priv:<id>:brand") distinct from any user
// private name so it can never be resolved via `resolve_private_name`.
// Returns the interned binding-name slice, callers add it to whichever
// constant pool needs it (constant indices are context-relative).
//
// Bound via declare_priv_slot, so it takes no register (see declare_priv_slot).
fn char[] CompilerContext.declare_class_brand(&self) {
    uint class_id = self.innermost_private_scope().class_id;
    char[] brand_name = self.private_slot_name(class_id, "brand");
    self.declare_priv_slot(brand_name);
    return brand_name;
}

// Declare the class's static brand, distinct from the instance brand and
// stamped on the constructor. Its name is source-illegal, like the instance brand.
fn char[] CompilerContext.declare_class_static_brand(&self) {
    uint class_id = self.innermost_private_scope().class_id;
    char[] sbrand_name = self.private_slot_name(class_id, "sbrand");
    self.declare_priv_slot(sbrand_name);
    return sbrand_name;
}

// Return the interned HString* for a lexical binding name (e.g.
// "#priv:brand" or a private name's own "#priv:foo" slot name), as a raw
// void* independent of any particular CompilerContext's constant pool.
// Used to stamp CompiledFunction.brand_name_hstr / resolve field-init
// symbols at construction time, when the reading code (VM construct path)
// has no access to the class-enclosing context's constants array.
fn void* CompilerContext.intern_private_binding_name(&self, char[] name) {
    Heap* hp = (Heap*)self.heap;
    HString* hstr = hp.str_intern(name);
    return (void*)hstr;
}

// Resolve a private name (without '#') to its declaring entry, searching from
// the innermost class scope outward. Faults with a SyntaxError if none declares it.
// `name` is re-interned before comparison, since stored names are interned too.
fn PrivateNameEntry*? CompilerContext.resolve_private_name(&self, char[] name) {
    char[] canonical_name = self.intern_slot_name(name);
    PrivateNameTable* t = self.private_name_table;
    uint i = t.count;
    while (i > 0) {
        i--;
        if (str_eq(t.entries[i].name, canonical_name)) {
            return &t.entries[i];
        }
    }
    char[128] buf;
    usz n = (usz)(io::bprintf(&buf, "private name '#%s' is not declared", (String)name) ?? buf[:0]).len;
    self.record_error(buf[:n]);
    return COMPILE_ERROR~;
}

// Declare a private accessor name, or merge into an existing entry of the
// same name IF the existing entry is itself an accessor (getter XOR
// setter) and this declaration supplies the other half (`get #x` + `set
// #x`). Any other re-use of the name (field, method, or a second getter/
// setter of the same kind) is a duplicate-declaration error.
fn void? CompilerContext.declare_or_merge_private_accessor(&self, char[] name, bool is_getter, bool is_setter, bool is_static_decl) {
    PrivateNameTable* t = self.private_name_table;
    uint scope_begin = self.innermost_private_scope().start;
    for (uint i = scope_begin; i < t.count; i++) {
        if (str_eq(t.entries[i].name, name)) {
            PrivateNameEntry* e = &t.entries[i];
            // ECMA-262 class early errors: both halves of a private accessor must
            // agree on static-ness, so `get #f` with `static set #f` is an error.
            bool mergeable = e.is_method
                && e.is_static == is_static_decl
                && ((is_getter && e.has_getter == false && e.has_setter)
                    || (is_setter && e.has_setter == false && e.has_getter));
            if (!mergeable) return COMPILE_ERROR~;
            if (is_getter) e.has_getter = true;
            if (is_setter) e.has_setter = true;
            return;
        }
    }
    PrivateNameEntry* entry = self.declare_private_name(name)!;
    entry.is_method = true;
    entry.has_getter = is_getter;
    entry.has_setter = is_setter;
    entry.is_static = is_static_decl;
}

// Emit the shared prelude for a private-field access `obj.#name`: resolve
// the name (SyntaxError if undeclared), CHK_BRAND `obj_reg` against the
// OWNING CLASS's brand symbol (own-only presence check; TypeError at
// runtime if absent. The brand, not this field's own key, is the
// unforgeable per-class marker every field/method shares), then load this
// name's own runtime symbol into a fresh register via GETVAR. Returns the
// register holding the resolved field symbol, the caller emits
// GETPROP/PUTPROP with it.
//
// When `defer_brand_check` is true, the CHK_BRAND is skipped (but the brand
// symbol is still loaded). The caller must emit the CHK_BRAND later and free
// the brand_reg via `self.free_reg(self.deferred_brand_reg)`. The register
// is stored in `self.deferred_brand_reg` for the caller to retrieve.
fn ushort? CompilerContext.emit_private_access(&self, char[] name, ushort obj_reg) {
    PrivateNameEntry* entry = self.resolve_private_name(name)!;
    // The binding-name constants go into THIS context's pool, entry only
    // carries the stable name text, never a pool index, because this runs
    // inside method/initializer bodies whose pools differ from the
    // class-enclosing context that declared the entry.
    uint brand_bind_idx = self.add_string_constant(entry.brand_slot_name);
    // Deferred destructuring targets pre-allocate the brand register below the
    // GETPROP result register (see deferred_brand_reg_hint). Otherwise the
    // getter's call window at [result_reg, result_reg + 1] could clobber it.
    ushort brand_reg = self.deferred_brand_reg_hint != 0xFFFF
        ? self.deferred_brand_reg_hint : self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)brand_reg, brand_bind_idx);
    uint name_const_idx = self.add_string_constant(name);
    uint name_c = name_const_idx <= 0xFE ? name_const_idx : 0xFF;
    if (self.defer_brand_check) {
        // Defer CHK_BRAND until after the source property is read (GetV), as
        // ECMA-262 DestructuringAssignmentEvaluation requires.
        self.deferred_brand_reg = brand_reg;
        self.deferred_brand_name_c = name_c;
        self.deferred_brand_obj_reg = obj_reg;
    } else {
        self.emit_abc(Opcode.CHK_BRAND, (uint)obj_reg, (uint)brand_reg, name_c);
        self.free_reg(brand_reg);
    }

    ushort key_reg = self.alloc_reg();
    uint slot_bind_idx = self.add_string_constant(entry.slot_name);
    self.emit_a_bc(Opcode.GETVAR, (uint)key_reg, slot_bind_idx);
    return key_reg;
}
