module boomkat::compiler;

import boomkat::ast;
import boomkat::features;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::lexer;
import boomkat::types;
import boomkat::relexstats;
import boomkat::frontendstats;
import std::time;

fn CompiledFunction*? CompilerContext.defer_function(&self, uint scope, char[] name) {
    ast::AstIndex* idx = ast::index_state;
    uint rec = idx.tree.rhs.data[idx.res.scopes.data[scope].node];
    // Establish the unit-owned source before allocating a deferred template.
    SourceBuf* source = idx.share_source(self.lexer.source);
    if (source == null) return COMPILE_ERROR~;
    if (source.line_starts.len == 0) {
        source.line_starts = mem::new_array(uint, idx.tree.line_starts.len)[:idx.tree.line_starts.len];
        mem::copy(source.line_starts.ptr, idx.tree.line_starts.data,
            idx.tree.line_starts.len * uint::size);
    }
    bytecode::source_buf_release(source);
    Heap* h = (Heap*)self.heap;
    CompiledFunction* f = (CompiledFunction*)h.alloc_func(h.heap_udata, CompiledFunction::size);
    if (f == null) return COMPILE_ERROR~;
    mem::clear(f, CompiledFunction::size);
    f.realm = h.realm;
    f.flags.htype = HType.OBJECT;
    f.flags.is_strict = (idx.tree.field(rec, ast::FN_FLAGS) & ast::FNF_STRICT) != 0;
    f.flags.is_constructable = self.is_constructable;
    f.flags.needs_env = true;
    f.num_args = (ushort)idx.tree.list_len(idx.tree.field(rec, ast::FN_PARAMS));
    f.num_formals = f.num_args;
    f.lazy_paren = idx.tree.field(rec, ast::FN_PAREN) + 1;
    attach_function_info(f, name, false, idx.tree.field(rec, ast::FN_SRC_START),
        idx.tree.field(rec, ast::FN_SRC_END), false, self.lexer.source);
    if (self.lexer.source_name.len > 0) {
        char[] file = mem::new_array(char, self.lexer.source_name.len + 1);
        mem::copy(file.ptr, self.lexer.source_name.ptr, self.lexer.source_name.len);
        f.filename_ptr = file.ptr;
        f.filename_len = (uint)self.lexer.source_name.len;
    }
    f.lazy_outer_with = self.in_with();
    self.record_outer_names(f, scope);
    h.track_compiled_func(f);
    return f;
}

// Whether a function around the slice being reparsed may bind `name`. Only the
// defining compile saw those functions; without its record every name may be.
fn bool outer_may_bind(ast::AstIndex* idx, HString* name) {
    CompiledFunction* f = idx.reparsed;
    if (f == null || !f.lazy_outer_known) return true;
    for (uint i = 0; i < f.const_count; i++) {
        if (f.constants[i].get_heapptr() == (void*)name) return true;
    }
    return false;
}

// Record on the template `f` of the function scope `scope` which names its body
// mentions that an enclosing function binds. The body's own source cannot show
// them once it is reparsed alone, and a free name outside that set is a global.
// Nothing is recorded when a `with` or a direct eval around the function could
// bind a name later, or when the body kept no list of the names it mentions.
fn void CompilerContext.record_outer_names(&self, CompiledFunction* f, uint scope) {
    ast::AstIndex* idx = ast::index_state;
    Heap* h = (Heap*)self.heap;
    uint fn_node = idx.res.scopes.data[scope].node;
    if (!idx.use || !idx.tree.body_was_recorded(fn_node)) return;
    if (self.has_direct_eval || self.has_with_stmt || self.in_with()
        || self.in_eval_code || self.capture_all) return;
    if (idx.unknown_outer && (idx.reparsed == null || !idx.reparsed.lazy_outer_known)) return;
    for (uint s = idx.res.scopes.data[scope].parent; s != 0; s = idx.res.scopes.data[s].parent) {
        ast::Scope* sc = &idx.res.scopes.data[s];
        if (sc.kind == ast::ScopeKind.WITH
            || (sc.flags & (ast::SCOPE_HAS_EVAL | ast::SCOPE_EVAL_PARAMS)) != 0) return;
    }
    uint refs = idx.tree.rhs.data[idx.tree.field(idx.tree.rhs.data[fn_node], ast::FN_BODY)];
    uint nrefs = idx.tree.field(refs, 1);
    // One slot at least, so a template with no outer names still owns a pool.
    TVal* names = (TVal*)h.alloc_func(h.heap_udata, (usz)(nrefs + 1) * TVal::size);
    if (names == null) return;
    uint count = 0;
    for (uint i = 0; i < nrefs; i++) {
        uint atom = idx.tree.field(refs, 2 + i);
        HString* name = h.ensure_interned(h.str_intern(idx.tree.atoms.get(atom)));
        bool bound = idx.unknown_outer && outer_may_bind(idx, name);
        // From the function's own scope, which binds a function expression's name.
        for (uint s = scope; s != 0 && !bound; s = idx.res.scopes.data[s].parent) {
            bound = idx.res.scopes.data[s].kind != ast::ScopeKind.GLOBAL && idx.res.lookup(s, atom) != 0;
        }
        if (!bound) continue;
        // Held like any pool string, so nothing releases it under the template.
        names[count++].set_string_borrowed(name);
        ((types::HeapHeader*)name).incref();
    }
    f.constants = names;
    f.const_count = count;
    f.lazy_outer_known = true;
    // Each of them may be a capture; add_inner_func keeps the ones this
    // function's parent can resolve, and so fixes the slot layout.
    f.capture_names = (uint*)h.alloc_func(h.heap_udata, (usz)(count + 1) * uint::size);
    if (f.capture_names == null) return;
    for (uint i = 0; i < count; i++) f.capture_names[i] = i;
    f.capture_count = count;
}

fn void? materialize_function(CompiledFunction* f, Heap* h) {
    if (f.lazy_paren == 0) return;
    materialize_function_body(f, h)!;
}

fn void? materialize_function_body(CompiledFunction* f, Heap* h) @noinline {
    $if $feat(RELEX_STATS):
        relexstats::RelexKind relex_prev = relexstats::relex_enter(relexstats::RelexKind.MATERIALIZE);
        defer relexstats::relex_leave(relex_prev);
    $endif
    $if $feat(FRONTEND_STATS):
        time::Time fs_start = time::now();
        frontendstats::materialize_calls++;
        defer { frontendstats::materialize_total_us += (ulong)(time::now() - fs_start); }
    $endif
    $if features::SOURCE_COMPILER:
    heap::Realm* caller_realm = h.realm;
    if (h.realm != f.realm) h.enter_realm(f.realm);
    defer h.enter_realm(caller_realm);
    uint end = (uint)(f.src_ptr - f.src_buf.data) + f.src_len;
    char[] source = f.src_buf.data[:end];
    Lexer lex = lexer::lexer_init(source, h);
    lex.source_name = f.filename_ptr[:f.filename_len];
    defer lex.free_arena();
    ast::AstIndex* idx = ast::index_begin(source, h, {
        .function_body = true, .function_start = f.lazy_paren - 1,
        .strict = f.flags.is_strict,
        .defer_functions = defer_functions_allowed(),
    }, f.src_buf);
    defer ast::index_end(idx);
    require_ast(&lex, idx)!;
    CompilerContext ctx;
    ctx.init(&lex, h);
    defer ctx.cleanup();
    ctx.is_strict = f.flags.is_strict;
    ctx.is_constructable = f.flags.is_constructable;
    ctx.outer_with = f.lazy_outer_with;
    ctx.is_named_func_expr = f.flags.is_namebinding;
    if (ctx.is_named_func_expr) ctx.named_func_expr_name = f.name_ptr[:f.name_len];
    // The source slice has no declarations for its enclosing scopes. Keep
    // free names in the captured environment rather than proving them global.
    idx.unknown_outer = true;
    idx.reparsed = f;
    ctx.gen_function(2)!;
    CompiledFunction* ready = ctx.finish(track: false)!;
    if (!adopt_capture_slots(ready, f, h)) return COMPILE_ERROR~;
    CompiledFunction saved = *f;
    *f = *ready;
    if (saved.constants != null) h.free_func(h.heap_udata, saved.constants);
    if (saved.capture_names != null) h.free_func(h.heap_udata, saved.capture_names);
    f.next = saved.next;
    f.prev = saved.prev;
    f.flags.reachable = saved.flags.reachable;
    f.flags.temproot = saved.flags.temproot;
    f.flags.is_namebinding = saved.flags.is_namebinding;
    f.realm = saved.realm;
    f.name_ptr = saved.name_ptr;
    f.name_len = saved.name_len;
    f.closure_name = saved.closure_name;
    f.src_ptr = saved.src_ptr;
    f.src_len = saved.src_len;
    f.src_buf = saved.src_buf;
    if (f.filename_ptr != null) mem::free(f.filename_ptr);
    f.filename_ptr = saved.filename_ptr;
    f.filename_len = saved.filename_len;
    h.free_func(h.heap_udata, ready);
    // The replacement's constants must be visible even if the old stub was
    // already visited by the incremental root scan.
    for (uint i = 0; i < f.const_count; i++) h.shade_root_tval(f.constants[i]);
    $else
        return COMPILE_ERROR~;
    $endif
}
