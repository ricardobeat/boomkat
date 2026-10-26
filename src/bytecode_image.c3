// Portable scalar encoding for the experimental bytecode tools.
module boomkat::image;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::features;
import std::collections::list;

faultdef INVALID_IMAGE, IMAGE_NOMEM, UNSUPPORTED_CONSTANT;

const uint VERSION = 7;
const uint NONE = 0xFFFFFFFF;
const uint MAX_FUNCTIONS = 65536;
const uint MAX_IMAGE_BYTES = 64 * 1024 * 1024;
// Learned entry facts and constructor capacity are reconstructed after loading.
const uint TRANSIENT_CALL_FLAGS_MASK = 0xEu | bytecode::CONSTRUCTOR_CAPACITY_MASK;

// Enum names and ordinals define the bytecode ABI, independently of pointer size.
macro uint opcode_signature() @const {
    uint $hash = 2166136261;
    $foreach $op : Opcode::values:
        $foreach $c : Opcode::names[$op.ordinal]:
            $hash = (uint)(((ulong)$hash ^ (uint)$c) * 16777619 & 0xFFFFFFFF);
        $endforeach
        $hash = (uint)(((ulong)$hash ^ (uint)$op.ordinal) * 16777619 & 0xFFFFFFFF);
    $endforeach
    return $hash;
}
const uint OPCODE_SIGNATURE = opcode_signature();
const uint CAPABILITIES = (features::ITERATOR_HELPERS ? 1 : 0)
    | (features::BIGINT ? 2 : 0) | (features::WEAKREF ? 4 : 0)
    | (features::SHARED_MEMORY ? 8 : 0) | (features::ASYNC_GENERATORS ? 16 : 0)
    | (features::REGEXP ? 32 : 0) | (features::COLLECTIONS ? 64 : 0)
    | (features::BUFFERS ? 128 : 0) | (features::PROXY ? 256 : 0)
    | (features::NORMALIZE ? 512 : 0) | (features::STRICT_ONLY ? 1024 : 0)
    | (features::EXTENDED_BUILTINS ? 0 : 2048);

struct ModuleDecl {
    char[] name;
    CompiledFunction* template;
}

struct Writer {
    List{char} bytes;
    List{CompiledFunction*} functions;
}

fn void Writer.word(&self, uint value) {
    for (uint i = 0; i < 4; i++) self.bytes.push((char)(value >> (i * 8)));
}
fn void Writer.wide(&self, ulong value) {
    self.word((uint)value);
    self.word((uint)(value >> 32));
}
fn void Writer.text(&self, char[] value) {
    self.word((uint)value.len);
    self.bytes.push_all(value);
}
fn uint Writer.function_id(&self, CompiledFunction* f) {
    if (f == null) return NONE;
    foreach (i, existing : self.functions) if (existing == f) return (uint)i;
    self.functions.push(f);
    return (uint)self.functions.len() - 1;
}
fn void Writer.string_ref(&self, void* raw) {
    self.word(raw != null ? 1 : 0);
    if (raw != null) self.text(((HString*)raw).get_data());
}

// Literal shapes describe ordered default data properties. Native shape ids
// belong to the source heap and are never part of the portable representation.
fn void? Writer.literal_shape(&self, Heap* heap, uint id) {
    hobject::Shape* leaf = heap.get_shape(id);
    if (leaf == null) return INVALID_IMAGE~;
    uint count = leaf.offset + leaf.own_count;
    if (count == 0 || count > 256) return INVALID_IMAGE~;
    HString*[256] keys = {};
    uint seen = 0;
    for (hobject::Shape* shape = leaf; shape != null; shape = shape.parent_shape) {
        if (shape.offset > count || shape.own_count > count - shape.offset) return INVALID_IMAGE~;
        for (uint i = 0; i < shape.own_count; i++) {
            hobject::ShapeProperty* property = &shape.props()[i];
            HString* key = property.key.borrow();
            uint index = shape.offset + i;
            if (keys[index] != null || property.flags != hobject::PROP_FLAGS_WEC
                || key == null || !key.flags.is_interned || key.is_symbol()
                || key.is_arridx() || key.is_hidden()) return INVALID_IMAGE~;
            keys[index] = key;
            seen++;
        }
    }
    if (seen != count) return INVALID_IMAGE~;
    for (uint i = 0; i < count; i++) {
        for (uint j = 0; j < i; j++) if (keys[j] == keys[i]) return INVALID_IMAGE~;
    }
    self.word(count);
    foreach (key : keys[:count]) self.text(key.get_data());
}

fn char[]? encode(Heap* heap, CompiledFunction* root, ModuleDecl[] declarations) {
    if (heap == null || root == null) return INVALID_IMAGE~;
    if (root.flags.is_module) {
        if (!root.flags.is_strict) return INVALID_IMAGE~;
    } else if (declarations.len != 0 || root.has_tla()) {
        return INVALID_IMAGE~;
    }
    Writer w;
    w.bytes.init(mem);
    w.functions.init(mem);
    defer w.functions.free();
    defer w.bytes.free();
    w.function_id(root);
    // Discover the graph before records: field initializers may share templates.
    for (sz i = 0; i < w.functions.len(); i++) {
        CompiledFunction* f = w.functions[i];
        foreach (inner : f.inner_funcs[:f.inner_count]) w.function_id(inner);
        w.function_id(f.field_init_func);
        if (w.functions.len() > MAX_FUNCTIONS) return INVALID_IMAGE~;
    }
    w.text("BKBC");
    w.word(VERSION);
    w.word(OPCODE_SIGNATURE);
    w.word(CAPABILITIES);
    w.word((uint)w.functions.len());
    foreach (f : w.functions) {
        // These compiler-only contexts need a separate portable representation.
        if (f.eval_private_name_count != 0 || f.lazy_paren != 0) return UNSUPPORTED_CONSTANT~;
        // The GC header and learned call-cache facts are reconstructed, never copied.
        w.word((uint)f.flags & 0xFFFFFF80);
        w.word((uint)f.call_flags & ~TRANSIENT_CALL_FLAGS_MASK);
        w.word(f.num_regs); w.word(f.arguments_reg);
        w.word(f.num_args); w.word(f.num_formals); w.word(f.capture_parent_reg);
        w.word(f.formal_names != null ? 1 : 0);
        if (f.formal_names != null) foreach (name : f.formal_names[:f.num_args]) w.word(name);
        w.text(f.name_ptr[:f.name_len]);
        w.text(f.filename_ptr[:f.filename_len]);
        w.text(f.src_ptr[:f.src_len]);
        w.word(f.code_count);
        foreach (pc, ins : f.code[:f.code_count]) {
            if (ins.op == Opcode.NEWOBJ_SHAPE) {
                // Literal specialization excludes wide functions. A prefix
                // would also extend the reconstructed heap-local operand.
                if (pc != 0 && f.code[pc - 1].op == Opcode.WIDE) return INVALID_IMAGE~;
                w.word(bytecode::make_a_bc(ins.op, ins.a, 0).to_raw());
                w.literal_shape(heap, ins.get_bc())!;
            } else {
                w.word(ins.to_raw());
            }
        }
        w.word(f.const_count);
        foreach (v : f.constants[:f.const_count]) {
            if (v.is_undefined()) { w.word(0); }
            else if (v.is_null()) { w.word(1); }
            else if (v.is_boolean()) { w.word(2); w.word(v.get_boolean() ? 1 : 0); }
            else if (v.is_fastint()) { w.word(3); w.wide((ulong)v.get_fastint()); }
            else if (v.is_number()) { w.word(4); w.wide(bitcast(v.get_number(), ulong)); }
            else if (v.is_string()) { w.word(5); w.text(((HString*)v.get_heapptr()).get_data()); }
            else { return UNSUPPORTED_CONSTANT~; }
        }
        w.word(f.capture_count);
        foreach (i, name : f.capture_names[:f.capture_count]) {
            w.word(name); w.word(f.capture_cells != null ? f.capture_cells[i] : 0);
        }
        w.word(f.await_live_count);
        foreach (entry : f.await_live[:f.await_live_count]) {
            w.word(entry.pc); w.word(entry.num_regs); w.wide(entry.mask);
        }
        w.word(f.source_map_count);
        foreach (entry : f.source_map[:f.source_map_count]) {
            w.word(entry.pc); w.word(entry.position.line);
            w.word(entry.position.column); w.word(entry.position.offset);
        }
        w.word(f.inner_count);
        foreach (inner : f.inner_funcs[:f.inner_count]) w.word(w.function_id(inner));
        w.word(w.function_id(f.field_init_func));
        w.string_ref(f.brand_name_hstr);
        w.string_ref(f.super_binding_name);
        w.string_ref(f.static_super_binding_name);
        w.string_ref(f.home_object_binding_name);
        w.word(f.direct_eval_offset_count);
        foreach (offset : f.direct_eval_offsets[:f.direct_eval_offset_count]) w.word(offset);
        w.word(f.eval_var_count);
        foreach (index : f.eval_var_idxs[:f.eval_var_count]) w.word(index);
    }
    w.word((uint)declarations.len);
    foreach (decl : declarations) {
        w.text(decl.name);
        w.word(w.function_id(decl.template));
    }
    if (w.bytes.len() > MAX_IMAGE_BYTES) return INVALID_IMAGE~;
    return mem::@clone_slice(w.bytes.entries[:w.bytes.len()]);
}

struct Reader {
    char[] bytes;
    usz offset;
    Heap* heap;
    CompiledFunction** functions;
    uint function_count;
}
fn uint? Reader.word(&self) {
    if (self.offset > self.bytes.len || self.bytes.len - self.offset < 4) return INVALID_IMAGE~;
    uint value = 0;
    for (uint i = 0; i < 4; i++) value |= (uint)self.bytes[self.offset++] << (i * 8);
    return value;
}
fn ulong? Reader.wide(&self) {
    uint low = self.word()!;
    uint high = self.word()!;
    return (ulong)low | ((ulong)high << 32);
}
fn char[]? Reader.text(&self) {
    uint len = self.word()!;
    if (len > self.bytes.len - self.offset) return INVALID_IMAGE~;
    char[] text = self.bytes[self.offset:len];
    self.offset += len;
    return text;
}
fn char*? Reader.owned_text(&self, uint* len) {
    char[] text = self.text()!;
    *len = (uint)text.len;
    if (text.len == 0) return (char*)null;
    char* ptr = (char*)alloc::malloc_try(mem, (sz)text.len)!;
    mem::copy(ptr, text.ptr, (sz)text.len);
    return ptr;
}
fn void*? Reader.array(&self, uint count, usz element_size) {
    if (count == 0) return (void*)null;
    if ((ulong)count * element_size > MAX_IMAGE_BYTES) return INVALID_IMAGE~;
    void* ptr = self.heap.alloc_func(self.heap.heap_udata, (usz)count * element_size);
    if (ptr == null) return IMAGE_NOMEM~;
    mem::clear(ptr, (sz)((usz)count * element_size));
    return ptr;
}
fn uint? Reader.count(&self, uint min_bytes) {
    uint count = self.word()!;
    if ((ulong)count * min_bytes > self.bytes.len - self.offset) return INVALID_IMAGE~;
    return count;
}
fn CompiledFunction*? Reader.function_ref(&self) {
    uint id = self.word()!;
    if (id == NONE) return (CompiledFunction*)null;
    if (id >= self.function_count) return INVALID_IMAGE~;
    return self.functions[id];
}
fn void*? Reader.string_ref(&self) {
    uint present = self.word()!;
    if (present == 0) return (void*)null;
    if (present != 1) return INVALID_IMAGE~;
    HString* str = self.heap.str_intern(self.text()!);
    if (str == null) return IMAGE_NOMEM~;
    return (void*)str;
}
fn ushort? Reader.short_word(&self) {
    uint value = self.word()!;
    if (value > ushort::max) return INVALID_IMAGE~;
    return (ushort)value;
}

// The reader has paused collection while the function graph is reconstructed.
// Interned keys acquire shape owners through the existing transition helpers.
fn uint? Reader.literal_shape(&self) {
    uint count = self.count(4)!;
    if (count == 0 || count > 256) return INVALID_IMAGE~;
    HString*[256] keys = {};
    uint id = 0;
    for (uint i = 0; i < count; i++) {
        HString* key = self.heap.str_intern(self.text()!);
        if (key == null) return IMAGE_NOMEM~;
        if (key.is_symbol() || key.is_arridx() || key.is_hidden()) return INVALID_IMAGE~;
        for (uint j = 0; j < i; j++) if (keys[j] == key) return INVALID_IMAGE~;
        keys[i] = key;
        id = self.heap.transition_shape_new(id, key);
        if (id == heap::SHAPE_NONE) return IMAGE_NOMEM~;
        // Shared prefixes must not turn into a private dictionary as a larger
        // literal is rebuilt. The compiler applies this same construction rule.
        self.heap.get_shape(id).shared = true;
    }
    if (id > ushort::max) return INVALID_IMAGE~;
    self.heap.get_shape(id).pinned = true;
    return id;
}

// Images come from the matching host tool. Structural validation catches damaged
// files; instruction operands require trusted compiler output.
fn CompiledFunction*? decode(Heap* heap, char[] bytes, List{ModuleDecl}* declarations) {
    if (bytes.len > MAX_IMAGE_BYTES) return INVALID_IMAGE~;
    Reader r = { .bytes = bytes, .heap = heap };
    if (r.text()! != (char[])"BKBC" || r.word()! != VERSION || r.word()! != OPCODE_SIGNATURE) return INVALID_IMAGE~;
    uint capabilities = r.word()!;
    if (capabilities != CAPABILITIES) return INVALID_IMAGE~;
    uint count = r.word()!;
    if (count == 0 || count > MAX_FUNCTIONS || count > bytes.len / 64) return INVALID_IMAGE~;
    CompiledFunction** functions = mem::new_array(CompiledFunction*, count);
    defer mem::free(functions);
    r.functions = functions;
    r.function_count = count;
    // Stop collection until all constants and cross-template references are rooted.
    bool in_step = heap.gc_in_step;
    heap.gc_in_step = true;
    defer heap.gc_in_step = in_step;
    for (uint i = 0; i < count; i++) {
        functions[i] = (CompiledFunction*)r.array(1, CompiledFunction::size)!;
        functions[i].flags.htype = HType.OBJECT;
        functions[i].realm = heap.realm;
        uint tracked = heap.compiled_func_count;
        heap.track_compiled_func(functions[i]);
        if (heap.compiled_func_count == tracked) {
            heap.free_func(heap.heap_udata, functions[i]);
            return IMAGE_NOMEM~;
        }
    }
    foreach (f : functions[:count]) {
        uint flags = r.word()!;
        if ((flags & 0x7F) != 0) return INVALID_IMAGE~;
        if (features::STRICT_ONLY && (flags & 0x80) == 0) return INVALID_IMAGE~;
        f.flags = (FuncFlags)flags;
        f.flags.htype = HType.OBJECT;
        if (!features::ASYNC_GENERATORS && (f.flags.is_async || f.flags.is_generator || f.flags.is_user_generator)) return INVALID_IMAGE~;
        uint call_flags = r.word()!;
        if (call_flags > ushort::max) return INVALID_IMAGE~;
        f.call_flags = (CallFlags)(ushort)(call_flags & ~TRANSIENT_CALL_FLAGS_MASK);
        f.num_regs = r.short_word()!; f.arguments_reg = r.short_word()!;
        f.num_args = r.short_word()!; f.num_formals = r.short_word()!;
        f.capture_parent_reg = r.short_word()!;
        if (f.num_args > f.num_regs) return INVALID_IMAGE~;
        if (r.word()! != 0) {
            f.formal_names = (uint*)r.array(f.num_args, uint::size)!;
            for (uint i = 0; i < f.num_args; i++) f.formal_names[i] = r.word()!;
        }
        f.name_ptr = r.owned_text(&f.name_len)!;
        f.filename_ptr = r.owned_text(&f.filename_len)!;
        f.src_ptr = r.owned_text(&f.src_len)!;
        f.code_count = r.count(4)!;
        if (f.code_count == 0) return INVALID_IMAGE~;
        f.code = (Instruction*)r.array(f.code_count, Instruction::size)!;
        for (uint i = 0; i < f.code_count; i++) {
            uint raw = r.word()!;
            if ((raw & 0xFF) >= Opcode::values.len) return INVALID_IMAGE~;
            f.code[i] = (Instruction)raw;
            if (!f.code[i].op.is_enabled()) return INVALID_IMAGE~;
            if (f.code[i].op == Opcode.NEWOBJ_SHAPE) {
                if (f.code[i].get_bc() != 0 || f.code[i].a >= f.num_regs
                    || (i != 0 && f.code[i - 1].op == Opcode.WIDE)) return INVALID_IMAGE~;
                uint shape = r.literal_shape()!;
                f.code[i] = bytecode::make_a_bc(Opcode.NEWOBJ_SHAPE, f.code[i].a, shape);
            }
        }
        f.const_count = r.count(4)!;
        f.constants = (TVal*)r.array(f.const_count, TVal::size)!;
        for (uint i = 0; i < f.const_count; i++) {
            TVal* v = &f.constants[i];
            switch (r.word()!) {
                case 0: v.set_undefined();
                case 1: v.set_null();
                case 2:
                    uint boolean = r.word()!;
                    if (boolean > 1) return INVALID_IMAGE~;
                    v.set_boolean(boolean != 0);
                case 3: v.set_fastint((long)r.wide()!);
                case 4: v.set_number(bitcast(r.wide()!, double));
                case 5:
                    HString* str = heap.str_intern(r.text()!);
                    if (str == null) return IMAGE_NOMEM~;
                    v.set_string(str);
                default: return INVALID_IMAGE~;
            }
        }
        f.regexp_cache_count = f.const_count;
        f.regexp_cache = (void**)r.array(f.const_count, void*::size)!;
        f.capture_count = r.count(8)!;
        f.capture_names = (uint*)r.array(f.capture_count, uint::size)!;
        f.capture_cells = (ushort*)r.array(f.capture_count, ushort::size)!;
        for (uint i = 0; i < f.capture_count; i++) {
            f.capture_names[i] = r.word()!;
            f.capture_cells[i] = r.short_word()!;
            if (f.capture_names[i] >= f.const_count) return INVALID_IMAGE~;
        }
        for (uint i = 0; f.formal_names != null && i < f.num_args; i++) {
            uint name = f.formal_names[i];
            if (name != bytecode::NO_FORMAL_NAME && (name >= f.const_count || !f.constants[name].is_string())) return INVALID_IMAGE~;
        }
        f.await_live_count = r.count(16)!;
        f.await_live = (AwaitLiveEntry*)r.array(f.await_live_count, AwaitLiveEntry::size)!;
        for (uint i = 0; i < f.await_live_count; i++) {
            f.await_live[i].pc = r.word()!;
            f.await_live[i].num_regs = r.word()!;
            f.await_live[i].mask = r.wide()!;
            if (f.await_live[i].pc >= f.code_count || f.await_live[i].num_regs > f.num_regs) return INVALID_IMAGE~;
        }
        f.source_map_count = r.count(16)!;
        f.source_map = (SourceEntry*)r.array(f.source_map_count, SourceEntry::size)!;
        for (uint i = 0; i < f.source_map_count; i++) {
            SourceEntry* entry = &f.source_map[i];
            entry.pc = r.word()!; entry.position.line = r.word()!;
            entry.position.column = r.word()!; entry.position.offset = r.word()!;
            if (entry.pc >= f.code_count || (i != 0 && entry.pc <= f.source_map[i - 1].pc)) return INVALID_IMAGE~;
        }
        f.inner_count = r.count(4)!;
        f.inner_funcs = (CompiledFunction**)r.array(f.inner_count, CompiledFunction*::size)!;
        for (uint i = 0; i < f.inner_count; i++) {
            f.inner_funcs[i] = r.function_ref()!;
            if (f.inner_funcs[i] == null) return INVALID_IMAGE~;
        }
        f.field_init_func = r.function_ref()!;
        f.brand_name_hstr = r.string_ref()!;
        f.super_binding_name = r.string_ref()!;
        f.static_super_binding_name = r.string_ref()!;
        f.home_object_binding_name = r.string_ref()!;
        f.direct_eval_offset_count = r.count(4)!;
        f.direct_eval_offsets = (uint*)r.array(f.direct_eval_offset_count, uint::size)!;
        for (uint i = 0; i < f.direct_eval_offset_count; i++) {
            uint offset = r.word()!;
            if (offset >= f.code_count
                || (i != 0 && offset <= f.direct_eval_offsets[i - 1])) return INVALID_IMAGE~;
            f.direct_eval_offsets[i] = offset;
        }
        f.eval_var_count = r.count(4)!;
        f.eval_var_idxs = (uint*)r.array(f.eval_var_count, uint::size)!;
        for (uint i = 0; i < f.eval_var_count; i++) {
            uint index = r.word()!;
            if (index >= f.const_count || !f.constants[index].is_string()) return INVALID_IMAGE~;
            f.eval_var_idxs[i] = index;
        }
    }
    uint decl_count = r.count(8)!;
    for (uint i = 0; i < decl_count; i++) {
        char[] name = r.text()!;
        CompiledFunction* template = r.function_ref()!;
        if (name.len == 0 || template == null) return INVALID_IMAGE~;
        declarations.push({ name, template });
    }
    CompiledFunction* root = functions[0];
    if (root.flags.is_module) {
        if (!root.flags.is_strict) return INVALID_IMAGE~;
    } else if (decl_count != 0 || root.has_tla()) {
        return INVALID_IMAGE~;
    }
    if (r.offset != bytes.len) return INVALID_IMAGE~;
    return root;
}
