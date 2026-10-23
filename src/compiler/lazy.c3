module boomkat::compiler;

import boomkat::ast;
import boomkat::features;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::lexer;
import boomkat::types;

fn CompiledFunction*? CompilerContext.defer_function(&self, uint scope, char[] name) {
    ast::AstIndex* idx = ast::index_state;
    uint rec = idx.tree.rhs.data[idx.res.scopes.data[scope].node];
    // Establish the unit-owned source before allocating a deferred template.
    SourceBuf* source = idx.share_source(self.lexer.source);
    if (source == null) return COMPILE_ERROR~;
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
    h.track_compiled_func(f);
    return f;
}

fn void? materialize_function(CompiledFunction* f, Heap* h) @inline {
    if (f.lazy_paren == 0) return;
    materialize_function_body(f, h)!;
}

fn void? materialize_function_body(CompiledFunction* f, Heap* h) @noinline {
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
    }, f.src_buf);
    defer ast::index_end(idx);
    require_ast(&lex, idx)!;
    CompilerContext ctx;
    ctx.init(&lex, h);
    defer ctx.cleanup();
    ctx.is_strict = f.flags.is_strict;
    ctx.is_constructable = f.flags.is_constructable;
    // The source slice has no declarations for its enclosing scopes. Keep
    // free names in the captured environment rather than proving them global.
    idx.unknown_outer = true;
    idx.defer_functions = true;
    ctx.gen_function(2)!;
    CompiledFunction* ready = ctx.finish(track: false)!;
    CompiledFunction saved = *f;
    *f = *ready;
    f.next = saved.next;
    f.prev = saved.prev;
    f.flags.reachable = saved.flags.reachable;
    f.flags.temproot = saved.flags.temproot;
    f.realm = saved.realm;
    f.name_ptr = saved.name_ptr;
    f.name_len = saved.name_len;
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
