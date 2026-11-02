module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;
import boomkat::jit;
import std::io;
import std::core::mem;

// Named/element property specialization and its ownership guards.

fn TVal* function_key_literal(CompiledFunction* cf, uint pc, uint reg) @feat(SLJIT) {
    for (uint back = pc; back > 0; back--) {
        Instruction ins = cf.code[back - 1];
        if (ins.a != reg || loop_target(
            ins,
            back - 1
        ) >= 0 || ins.op == Opcode.PUTPROP || ins.op == Opcode.PUTPROPC || ins.op == Opcode.PUTTHISC) continue;
        if (ins.op == Opcode.LDREG) {
            reg = ins.b;
            continue;
        }
        if (ins.op == Opcode.LDCONST) return &cf.constants[ins.get_bc()];
        return null;
    }
    return null;
}
fn int function_shape_slot(Shape* shape, void* key, PropFlags* flags) @feat(SLJIT) {
    while (shape != null) {
        for (uint i = 0; i < shape.own_count; i++) {
            ShapeProperty* property = &shape.props()[i];
            if (property.key.borrow() == key) {
                *flags = property.flags;
                return (int)(shape.offset + i);
            }
        }
        shape = shape.parent_shape;
    }
    return -1;
}
fn bool FunctionEmitter.shape(&self, uint id, Heap* h) @feat(SLJIT) {
    Shape* shape = h.get_shape(id);
    if (shape == null) return false;
    for (uint i = 0; i < self.plan.shape_count; i++) if (self.plan.shapes[i]
        == id) return self.plan.generations[i] == shape.generation;
    if (self.plan.shape_count == self.plan.shapes.len) return false;
    uint slot = self.plan.shape_count++;
    self.plan.shapes[slot] = id;
    self.plan.generations[slot] = shape.generation;
    return true;
}
// Store a value into a property slot. Old and new value tags are checked
// first; a traced object is stored only when the write barrier is a no-op.
fn void FunctionEmitter.slot_store(&self, int owner, int slot_base, long disp, uint value_reg, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
    // Keep the owner for the object-store barrier; r0 takes the values.
    e.mov(r1, 0, owner, 0);
    e.mov(r0, 0, mem | slot_base, disp);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    // Strings are reference counted and carry a decref on replacement, so
    // only primitives and traced objects are stored natively.
    void* old_object = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    self.out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, pc);
    e.bind(old_object);
    self.out.load(value_reg, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* new_object = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    self.out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, pc);
    e.bind(new_object);
    // Storing a traced object needs the write barrier. Skip it only when the
    // collector is not shading and the owner is young, or the value being
    // stored is already old.
    void* primitive = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    Heap heap_view;
    e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
    e.mov(r3, 0, mem | r3, (char*)&heap_view.gc_phase - (char*)&heap_view, jit::SLJIT_MOV_U8);
    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)heap::GcPhase.MARK, pc);
    HObjectBase base;
    e.mov(r3, 0, mem | r1, (char*)&base.gc - (char*)&base, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r3, r3, 0, imm, 2);
    void* young_owner = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, 0);
    e.op(jit::SLJIT_AND, r3, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    e.mov(r3, 0, mem | r3, (char*)&base.gc - (char*)&base, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r3, r3, 0, imm, 2);
    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, pc);
    e.bind(young_owner);
    e.bind(primitive);
    e.mov(mem | slot_base, disp, r0, 0);
}

// A store that adds a property the receiver and its whole prototype chain
// lack. The absent-property cache names the shape the append moves the
// receiver to, so the store needs no lookup of the key or of the transition.
// The guards mirror the interpreter's absent-put path: a receiver with a
// different chain, flags or storage leaves to the interpreter, which owns
// growth, reference counts and the write barrier. The receiver arrives in r0
// still boxed.
fn void FunctionEmitter.append_property(&self, CompiledFunction* cf, uint pc, ICEntry* ic, Heap* h) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    Instruction ins    = cf.code[pc];
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
    uint value_reg     = ins.op == Opcode.PUTTHISC ? ins.a : ins.b;
    HObject obj;
    long shape_offset  = (char*)&obj.shape_id - (char*)&obj;
    long proto_offset  = (char*)&obj.prototype - (char*)&obj;
    // The receiver must be an object.
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    // An ordinary extensible object: the append installs a plain data
    // property, so no exotic [[Set]] may intercept it.
    ObjFlags ordinary;
    ordinary.obj_class = OBJECT;
    ObjFlags forbidden;
    forbidden.exotic_proxyobj = true;
    forbidden.exotic_module_ns = true;
    forbidden.exotic_deferred_ns = true;
    ObjFlags extensible;
    extensible.extensible = true;
    e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, 0x003F0000U | (uint)forbidden);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
    e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, (uint)extensible);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)extensible, pc);
    // The receiver must be on the shape the cache names, and the recycle epoch
    // must still hold, or the recorded transition is stale.
    e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.shape_id, pc);
    Heap heap_view;
    e.mov(r2, 0, mem | jit::reg_s(1), function_cold_offset(0));
    e.mov(r2, 0, mem | r2, (char*)&heap_view.shape_recycle_epoch - (char*)&heap_view, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.shape_gen, pc);
    // The property storage must have a free slot and no hash table.
    e.mov(r1, 0, mem | r0, (char*)&obj.prop_count - (char*)&obj, jit::SLJIT_MOV_U32);
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_capacity - (char*)&obj, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r2, 0, pc);
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_hash - (char*)&obj);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0, pc);
    // An observed prototype needs the prototype epoch bumped, which only the
    // interpreter does.
    GcBits observed;
    observed.prototype_observed = true;
    observed.jit_observed = true;
    e.mov(r2, 0, mem | r0, (char*)&obj.gc - (char*)&obj, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, (uint)observed);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0, pc);
    // The chain must be the one the cache recorded: every link the same
    // object with the same shape, and nothing after the last link.
    e.mov(r3, 0, mem | r0, proto_offset);
    for (uint i = 0; i < ic.chain_len; i++) {
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)ic.chain.snapshot.protos[i], pc);
        e.mov(r2, 0, mem | r3, shape_offset, jit::SLJIT_MOV_U32);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.chain.snapshot.shapes[i], pc);
        e.mov(r2, 0, mem | r3, 0, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_AND, r2, r2, 0, imm, 0x003F0000U | (uint)forbidden);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
        e.mov(r3, 0, mem | r3, proto_offset);
    }
    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, pc);
    // The value takes the next free slot: the inline storage while the object
    // has none, and the block the heap allocated once it did.
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
    void* external = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
    e.op(jit::SLJIT_ADD, r2, r0, 0, imm, HObjectBase::size);
    e.bind(external);
    e.op(jit::SLJIT_SHL, r3, r1, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r3, 0);
    // The slot starts empty, so the store has no old value to release.
    e.mov(mem | r2, 0, imm, 0);
    self.slot_store(r0, r2, 0, value_reg, pc);
    // The receiver moves to the shape the cache names. The store keeps the
    // owner in r1.
    e.mov(r2, 0, mem | r1, (char*)&obj.prop_count - (char*)&obj, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_ADD, r2, r2, 0, imm, 1);
    e.mov(mem | r1, (char*)&obj.prop_count - (char*)&obj, r2, 0, jit::SLJIT_MOV_U32);
    e.mov(mem | r1, shape_offset, imm, ic.absent_next_shape, jit::SLJIT_MOV_U32);
}

fn bool FunctionEmitter.property(&self, CompiledFunction* cf, uint pc, bool write, Heap* h) @feat(SLJIT) {
    TemplateEmitter* e       = &self.out.e;
    Instruction ins          = cf.code[pc];
    ICEntry* ic              = (ICEntry*)cf.ic_entries + pc;
    FunctionFlow* saved_flow = self.out.flow;
    bool length_join         = (ins.op == Opcode.GETPROPC || ins.op == Opcode.GETPROPC_CACHED)
        && cf.constants[ins.c].get_heapptr() == h.str(
        heap::BuiltinStr.LENGTH
    );
    if (length_join && saved_flow != null) {
        self.flow_materialize();
        self.out.flow = null;
    }
    defer self.out.flow = saved_flow;
    if (!write && ins.op != Opcode.GETTHISC && (ins.op == Opcode.GETPROPC || ins.op == Opcode.GETPROPC_CACHED)
        && cf.constants[ins.c].get_heapptr() == h.str(
        heap::BuiltinStr.LENGTH
    ) && self.typed_length(cf, pc, ic, h)) return true;
    bool receiver_this = ins.op == Opcode.GETTHISC || ins.op == Opcode.PUTTHISC;
    bool computed      = ins.op == Opcode.GETPROP || ins.op == Opcode.GETPROP_CACHE || ins.op == Opcode.PUTPROP;
    uint value_reg     = ins.op == Opcode.PUTTHISC ? ins.a : ins.op == Opcode.PUTPROP ? ins.c : ins.b;
    void* key          = computed ? (void*)ic.key.borrow() : cf.constants[ins.c].get_heapptr();
    TVal* literal      = computed ? function_key_literal(cf, pc, write ? ins.b : ins.c) : null;
    if (computed && literal != null && literal.is_string()) {
        HString* text = literal.get_heapptr();
        if (text.equals("length")) key = h.str(heap::BuiltinStr.LENGTH);
    }
    uint base_reg    = write ? ins.a : ins.b;
    bool tracking    = FUNCTION_OBJECT_FLOW && self.out.flow != null && !computed;
    uint token       = tracking ? self.flow.token(base_reg, receiver_this) : 0;
    bool known_shape = tracking && (receiver_this ? self.flow.this_shape
        : self.flow.shapes[base_reg]) == ic.shape_id + 1;
    if (tracking && write) self.flow.heap_write();
    if (tracking && !write) {
        int previous = self.flow.loaded(token, key);
        if (previous >= 0) {
            uint value_token = self.flow.versions[previous];
            uint value_shape = self.flow.shapes[previous];
            self.out.load((uint)previous, jit::reg_r(0));
            self.property_store(ins.a, pc, ic);
            self.flow.same_value(ins.a, value_token, value_shape);
            self.flow.remember(token, key, ins.a);
            return true;
        }
    }
    // Shared read-cache hits can leave later sites unpopulated. Borrow a
    // warmed site's layout; generated guards still validate the live receiver.
    if (!computed && ic.key.borrow() == null) {
        for (uint i = 0; i < cf.code_count; i++) {
            if (cf.code[i].op != Opcode.GETPROPC && cf.code[i].op != Opcode.GETPROPC_CACHED) continue;
            ICEntry* candidate = (ICEntry*)cf.ic_entries + i;
            if (candidate.key.borrow() != key || candidate.prop_idx >= hobject::IC_PROP_MISSING
                || candidate.prop_flags.is_accessor) continue;
            Shape* layout = h.get_shape(candidate.shape_id);
            if (layout == null || layout.generation != candidate.shape_gen) continue;
            ic = candidate;
            break;
        }
    }
    known_shape = tracking && (receiver_this ? self.flow.this_shape : self.flow.shapes[base_reg]) == ic.shape_id + 1;
    int mem       = jit::SLJIT_MEM;
    int imm       = jit::SLJIT_IMM;
    int r0        = jit::reg_r(0);
    int r1        = jit::reg_r(1);
    int r2        = jit::reg_r(2);
    int r3        = jit::reg_r(3);
    bool matching = literal != null && literal.is_string();
    bool element  = false;
    if (computed) {
        self.out.load(write ? ins.b : ins.c, r1);
        if (matching && literal.get_heapptr() != key) {
            HString* left  = literal.get_heapptr();
            HString* right = key;
            matching = right != null && !left.is_symbol() && !right.is_symbol()
                && left.equals_hstring(right);
        }
        // A numeric key names an array element, which the dense part answers.
        // The site cache only records string keys, so an unrecorded key is an
        // index and the element path claims it. A write does not: storing into
        // the dense part has to consult the prototype chain and keep the
        // array's hole count in step, which the interpreter owns.
        element = !write && !matching && key == null;
        if (!element) {
            self.out.guard(
                jit::SLJIT_NOT_EQUAL,
                r1,
                0,
                imm,
                matching ? (long)loop_bits(*literal) : (long)((types::TAG_STRING << 48) | (ulong)key),
                pc
            );
        }
    }
    self.property_receiver(base_reg, receiver_this);
    // A store that adds a property the receiver and its whole prototype chain
    // lack: the absent-property cache names the shape the append moves the
    // receiver to, so the store needs no lookup of the key or of the
    // transition.
    if (write && !computed && ic.prop_idx == hobject::IC_PROP_ABSENT) {
        if (ic.key.borrow() == null || key == null || ic.key.borrow() != key || ic.has_proto
            || (uint)ic.chain_len > hobject::IC_MAX_CHAIN
            || h.get_shape(
            ic.absent_next_shape
        ) == null || ((HString*)key).is_arridx() || ((HString*)key).flags.is_hidden) {
            self.out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pc, true);
            return false;
        }
        self.append_property(cf, pc, ic, h);
        if (tracking) self.flow.guard_shape(token, ic.absent_next_shape);
        return true;
    }
    if (element) {
        self.array_element(cf, pc);
        return true;
    }
    if (!known_shape) {
        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    }
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    if (!known_shape) self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    HObject obj;
    long shape_offset = (char*)&obj.shape_id - (char*)&obj;
    long proto_offset = (char*)&obj.prototype - (char*)&obj;
    ObjFlags forbidden;
    forbidden.exotic_proxyobj = true;
    forbidden.exotic_module_ns = true;
    forbidden.exotic_deferred_ns = true;
    ObjFlags ordinary;
    ordinary.obj_class = OBJECT;
    uint flag_mask = 0x003F0000U | (uint)forbidden;
    void* length_done;
    if (!write && key == h.str(heap::BuiltinStr.LENGTH)) {
        e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_AND, r2, r2, 0, imm, flag_mask);
        ObjFlags array;
        array.obj_class = ARRAY;
        void* other = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)array);
        e.mov(r0, 0, mem | r0, HObjectBase::size, jit::SLJIT_MOV_U32);
        self.out.box(r0);
        self.store(ins.a, pc, true);
        length_done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
        e.bind(other);
    }
    Shape* shape     = h.get_shape(ic.shape_id);
    // Inherited reads cache their links on one prototype epoch, and a site
    // whose objects differ in shape keeps a set of own data reads, or of the
    // receiver shapes an inherited read answers for.
    bool epoch_chain = !write && ic.chain_len == hobject::IC_CHAIN_EPOCH;
    bool poly_chain  = !write && ic.chain_len == hobject::IC_CHAIN_POLY;
    bool proto_chain = !write && ic.chain_len == hobject::IC_CHAIN_PROTO;
    bool usable      = key != null && ic.key.borrow() == key && shape != null && shape.generation == ic.shape_gen
        && (epoch_chain || poly_chain || proto_chain || ic.chain_len <= hobject::IC_MAX_CHAIN)
        && !ic.prop_flags.is_accessor
        && ic.prop_idx < hobject::IC_PROP_MISSING
        // An inherited read on a dictionary receiver revalidates prop_count
        // below, since an appended own key would shadow the cached owner.
        && (!ic.has_proto || !shape.dict || ic.dict_count != 0)
        && (!write || (!ic.has_proto && ic.prop_flags.writable));
    if (usable && epoch_chain) {
        usable = ic.chain.epoch.owner != null && ic.chain.epoch.first != null && ic.chain.epoch.owner.find_prop_idx(
            key,
            h
        ) == (int)ic.prop_idx;
    }
    if (usable) {
        usable = self.shape(ic.shape_id, h);
        PropFlags flags;
        int index = function_shape_slot(shape, key, &flags);
        if (poly_chain) {
            // Every extra shape is a receiver this site has already read the
            // key from as an own data slot.
            ICPolySet* set = &ic.chain.poly;
            usable = index == (int)ic.prop_idx && !flags.is_accessor && set.count > 0
                && set.count <= hobject::IC_POLY_MAX;
            for (uint i = 0; usable && i < set.count; i++) {
                Shape* extra = h.get_shape(set.shapes[i]);
                usable = extra != null && !extra.dict && self.shape(
                    set.shapes[i],
                    h
                ) && function_shape_slot(extra, key, &flags) == (int)set.prop_idx[i] && !flags.is_accessor;
            }
        } else if (proto_chain) {
            // The entry's own receiver resolves the read through its recorded
            // link; every arm does the same for one more receiver shape.
            hobject::ICProtoReads* set = &ic.chain.proto;
            usable = index < 0 && !shape.dict && set.primary.owner != null && set.primary.first != null
                && set.count <= hobject::IC_PROTO_ARMS
                && set.primary.owner.find_prop_idx(
                key,
                h
            ) == (int)ic.prop_idx;
            for (uint i = 0; usable && i < set.count; i++) {
                Shape* extra = h.get_shape(set.arms[i].shape_id);
                usable = extra != null && !extra.dict && self.shape(
                    set.arms[i].shape_id,
                    h
                ) && set.arms[i].owner != null && set.arms[i].first != null && function_shape_slot(
                    extra,
                    key,
                    &flags
                ) < 0 && set.arms[i].owner.find_prop_idx(key, h) == (int)set.arms[i].prop_idx;
            }
        } else if (epoch_chain) {
            usable = index < 0 && !shape.dict;
        } else if (ic.chain_len == 0) {
            usable = usable && index == (int)ic.prop_idx && !flags.is_accessor && (!write || flags.writable);
        } else {
            usable = usable && index < 0 && (!shape.dict || ic.dict_count != 0);
            for (uint i = 0; usable && i < ic.chain_len; i++) {
                // Cache links are weak. Validate layouts through the shape table;
                // generated code follows live links before dereferencing objects.
                Shape* proto_shape = h.get_shape(ic.chain.snapshot.shapes[i]);
                usable = ic.chain.snapshot.protos[i] != null && proto_shape != null && self.shape(
                    ic.chain.snapshot.shapes[i],
                    h
                );
                if (!usable) break;
                index = function_shape_slot(proto_shape, key, &flags);
                if (i + 1 == ic.chain_len) {
                    usable = index == (int)ic.prop_idx && !flags.is_accessor;
                } else {
                    usable = index < 0 && !proto_shape.dict;
                }
            }
        }
    }
    // Array receivers normally record a bounded snapshot, not an epoch chain:
    // their Array prototype is exotic too. A named data read can still use a
    // one-link snapshot, provided neither length nor an indexed key is read.
    void* array_done;
    $if $feat(SLJIT_ARRAY_NAMED_READ):
        HString* name = key;
        bool array_snapshot = usable && !write && !computed && !known_shape
            && ic.has_proto && ic.chain != null && ic.chain_len == 1 && ic.dict_count == 0 && name != null
            && !name.is_arridx() && !name.is_hidden() && key != h.str(heap::BuiltinStr.LENGTH);
        if (array_snapshot) {
            // The IC roots its final owner. Do not add an array arm at sites
            // whose cached prototype is an ordinary object.
            HObject* owner = hobject::ic_cached_proto(ic);
            array_snapshot = owner != null && owner.get_class() == ARRAY;
        }
        if (array_snapshot) {
            if (saved_flow != null) {
                self.flow_materialize();
                self.out.flow = null;
                tracking = false;
            }
            self.property_receiver(base_reg, receiver_this);
            e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
            ObjFlags array_forbidden = forbidden;
            array_forbidden.exotic_array = true;
            array_forbidden.exotic_arguments = true;
            array_forbidden.exotic_stringobj = true;
            ObjFlags array_flags;
            array_flags.obj_class = ARRAY;
            array_flags.exotic_array = true;
            uint array_mask = 0x003F0000U | (uint)array_forbidden;
            e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
            e.op(jit::SLJIT_AND, r2, r2, 0, imm, array_mask);
            void* non_array = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)array_flags);
            e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.shape_id, pc);
            e.mov(r0, 0, mem | r0, proto_offset);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)ic.chain.snapshot.protos[0], pc);
            e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.chain.snapshot.shapes[0], pc);
            // Array.prototype is an array with named properties in allocated
            // storage. Other owner classes retain the ordinary fallback.
            e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
            e.op(jit::SLJIT_AND, r2, r2, 0, imm, array_mask);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)array_flags, pc);
            e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
            self.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pc);
            e.mov(r0, 0, mem | r2, (long)ic.prop_idx * 8);
            self.property_store(ins.a, pc, ic);
            array_done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
            e.bind(non_array);
            self.property_receiver(base_reg, receiver_this);
            e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        }
    $endif
    if (!usable) {
        self.out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pc, true);
    } else if (poly_chain) {
        // One compare per recorded shape, each naming the slot that shape's
        // layout gave the key. The entry's own shape is the first and the most
        // common; a receiver matching none leaves to the interpreter.
        if (tracking && saved_flow != null) {
            self.flow_materialize();
            self.out.flow = null;
        }
        ICPolySet* set = &ic.chain.poly;
        void*[hobject::IC_POLY_MAX + 1] arms;
        uint arm_count = 0;
        // A failed arm only compares the shape. Keep the receiver and its
        // shape live across the chain; successful arms jump directly out.
        self.property_receiver(base_reg, receiver_this);
        e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        e.mov(r1, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
        for (uint i = 0; i <= set.count; i++) {
            uint shape_id = i == 0 ? ic.shape_id : set.shapes[i - 1];
            uint slot     = i == 0 ? ic.prop_idx : set.prop_idx[i - 1];
            void* other   = e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, shape_id);
            e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
            void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
            // Shapes can be shared by different object classes. Inline slots
            // follow each class's payload, not always the common header.
            // GcBits.inline_words occupies bits 11..15; shifting by eight
            // converts that word offset directly into a byte offset.
            e.mov(r2, 0, mem | r0, (char*)&obj.gc - (char*)&obj, jit::SLJIT_MOV_U32);
            e.op(jit::SLJIT_LSHR, r2, r2, 0, imm, 8);
            e.op(jit::SLJIT_AND, r2, r2, 0, imm, 0xf8);
            e.op(jit::SLJIT_ADD, r2, r0, 0, r2, 0);
            e.bind(allocated);
            e.mov(r0, 0, mem | r2, (long)slot * 8);
            self.property_store(ins.a, pc, ic);
            arms[arm_count++] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
            e.bind(other);
        }
        self.out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pc, true);
        void* arms_done = e.label();
        for (uint i = 0; i < arm_count; i++) jit::sljit_set_label(arms[i], arms_done);
    } else if (proto_chain) {
        // The epoch guard covers every owner's layout and every repointed link,
        // so each arm only has to name the receiver shape it answers for and
        // the link the read stepped through. Arms are tried in order and the
        // last one's failure leaves to the interpreter.
        if (tracking && saved_flow != null) {
            self.flow_materialize();
            self.out.flow = null;
        }
        hobject::ICProtoReads* set = &ic.chain.proto;
        // Receiver shapes are shared by exotic objects too; only ordinary
        // objects have the absence proof recorded by this cache.
        self.property_receiver(base_reg, receiver_this);
        e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
        ObjFlags proto_forbidden = forbidden;
        proto_forbidden.exotic_array = true;
        proto_forbidden.exotic_arguments = true;
        proto_forbidden.exotic_stringobj = true;
        e.op(jit::SLJIT_AND, r2, r2, 0, imm, 0x003F0000U | (uint)proto_forbidden);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
        Heap heap_view;
        e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
        e.mov(r3, 0, mem | r3, (char*)&heap_view.prototype_epoch - (char*)&heap_view);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)set.primary.value, pc);
        void*[hobject::IC_PROTO_ARMS + 2] arms;
        uint arm_count = 0;
        for (uint i = 0; i <= set.count; i++) {
            uint shape_id  = i == 0 ? ic.shape_id : set.arms[i - 1].shape_id;
            uint slot      = i == 0 ? ic.prop_idx : set.arms[i - 1].prop_idx;
            HObject* first = i == 0 ? set.primary.first : set.arms[i - 1].first;
            HObject* owner = i == 0 ? set.primary.owner : set.arms[i - 1].owner;
            self.property_receiver(base_reg, receiver_this);
            e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
            e.mov(r1, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
            void* other = e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, shape_id);
            e.mov(r2, 0, mem | r0, proto_offset);
            void* link = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)first);
            // The owner keeps its identity while the epoch holds, but its
            // storage may have moved, so the slot is read from the live object.
            e.mov(r1, 0, imm, (long)owner);
            e.mov(r2, 0, mem | r1, (char*)&obj.prop_alloc - (char*)&obj);
            void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
            e.op(jit::SLJIT_ADD, r2, r1, 0, imm, (long)owner.gc.inline_words * 8);
            e.bind(allocated);
            e.mov(r0, 0, mem | r2, (long)slot * 8);
            self.property_store(ins.a, pc, ic);
            arms[arm_count++] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
            if (i == set.count) {
                self.out.link(other, pc, true);
                self.out.link(link, pc, true);
            } else {
                void* next = e.label();
                self.out.bind_to(other, next);
                self.out.bind_to(link, next);
            }
        }
        void* proto_done = e.label();
        for (uint i = 0; i < arm_count; i++) jit::sljit_set_label(arms[i], proto_done);
    } else {
        if (!known_shape) {
            e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
            e.op(jit::SLJIT_AND, r2, r2, 0, imm, flag_mask);
            HString* text = key;
            bool math_key = text != null && !text.is_symbol() && (text.equals(
                "min"
            ) || text.equals("max") || text.equals("abs") || text.equals("sqrt") || text.equals("imul"));
            if (math_key) {
                void* plain = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, (uint)ordinary);
                ObjFlags math;
                math.obj_class = MATH;
                self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)math, pc);
                e.bind(plain);
            } else {
                self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
            }
            e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.shape_id, pc);
            if (tracking) self.flow.guard_shape(token, ic.shape_id);
        }
        if (ic.has_proto && ic.dict_count != 0) {
            e.mov(r2, 0, mem | r0, (char*)&obj.prop_count - (char*)&obj, jit::SLJIT_MOV_U32);
            e.op(jit::SLJIT_ADD, r2, r2, 0, imm, 1);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.dict_count, pc);
        }
        if (epoch_chain) {
            // The epoch covers a repointed link and every layout change on the
            // chain, so only the first link and the shared counter remain.
            e.mov(r2, 0, mem | r0, proto_offset);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)ic.chain.epoch.first, pc);
            Heap heap_view;
            e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
            e.mov(r3, 0, mem | r3, (char*)&heap_view.prototype_epoch - (char*)&heap_view);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)ic.chain.epoch.value, pc);
            // The owner keeps its identity while the epoch holds, but its
            // storage may have moved, so the slot is read from the live object.
            e.mov(r1, 0, imm, (long)ic.chain.epoch.owner);
            e.mov(r2, 0, mem | r1, (char*)&obj.prop_alloc - (char*)&obj);
            void* owner_allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
            e.op(jit::SLJIT_ADD, r2, r1, 0, imm, (long)ic.chain.epoch.owner.gc.inline_words * 8);
            e.bind(owner_allocated);
            e.mov(r0, 0, mem | r2, (long)ic.prop_idx * 8);
            self.property_store(ins.a, pc, ic);
            if (tracking) self.flow.remember(token, key, ins.a);
        } else {
            for (uint i = 0; i < ic.chain_len; i++) {
                e.mov(r0, 0, mem | r0, proto_offset);
                self.out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)ic.chain.snapshot.protos[i], pc);
                e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
                self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.chain.snapshot.shapes[i], pc);
                e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
                e.op(jit::SLJIT_AND, r2, r2, 0, imm, flag_mask);
                self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
            }
            e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
            void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
            e.op(jit::SLJIT_ADD, r2, r0, 0, imm, HObjectBase::size);
            e.bind(allocated);
            if (write) {
                // Only ordinary named-property owners can be watched. The
                // append path has its own layout guard; indexed array stores
                // cannot register dependencies under the current registry.
                GcBits observed_write;
                observed_write.jit_observed = true;
                e.mov(r3, 0, mem | r0, (char*)&obj.gc - (char*)&obj, jit::SLJIT_MOV_U32);
                e.op(jit::SLJIT_AND, r3, r3, 0, imm, (uint)observed_write);
                self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pc);
                self.slot_store(r0, r2, (long)ic.prop_idx * 8, value_reg, pc);
            } else {
                e.mov(r0, 0, mem | r2, (long)ic.prop_idx * 8);
                self.property_store(ins.a, pc, ic);
                if (tracking) self.flow.remember(token, key, ins.a);
            }
        }
    }
    if (length_done != null) e.bind(length_done);
    if (array_done != null) e.bind(array_done);
    return usable || length_done != null;
}

// A computed read whose key is an array index. The receiver must be a dense
// array and the key a non-negative integer below the dense capacity; the
// element then lives in the array's dense part, whose address is the part
// pointer plus the index. Anything else leaves to the interpreter, which owns
// the named-property and hole paths.
fn void FunctionEmitter.array_element(&self, CompiledFunction* cf, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    Instruction ins    = cf.code[pc];
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
    // The receiver must be an object.
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    // The key must be a fastint: a fractional index names a property.
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pc);
    e.op(jit::SLJIT_AND, r1, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    // The payload is a signed 48-bit value, so a negative index is not an
    // element either.
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 47);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pc);
    // The receiver must be an array that keeps its indices in the dense part:
    // a named index property shadows the dense slot.
    HObject obj;
    e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    ObjFlags array;
    array.obj_class = ARRAY;
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, 0x003F0000U | (1U << 29));
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)array, pc);
    // The index must be below the dense capacity.
    e.mov(r2, 0, mem | r0, (char*)&obj.array_size - (char*)&obj, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r2, 0, pc);
    // The dense part follows the property values.
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
    self.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pc);
    e.mov(r3, 0, mem | r0, (char*)&obj.prop_capacity - (char*)&obj, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_SHL, r3, r3, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r3, 0);
    e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
    e.mov(r0, 0, mem | r2, 0);
    // A hole is not an element: the interpreter looks the index up by name.
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED, pc);
    self.store(ins.a, pc);
}

fn void FunctionEmitter.property_receiver(&self, uint reg, bool receiver_this) @feat(SLJIT) {
    if (!receiver_this) {
        self.out.load(reg, jit::reg_r(0));
    } else if (self.this_in_window) {
        self.out.load(INLINE_THIS_SLOT, jit::reg_r(0));
    } else {
        self.out.e.mov(jit::reg_r(0), 0, jit::reg_s(3), 0);
    }
}

// Feedback chooses a guarded representation; it never proves a future value.
fn void FunctionEmitter.property_store(&self, uint reg, uint pc, ICEntry* ic) @feat(SLJIT) {
    bool uncounted = ic.read_kind == 1 && ic.read_samples != 0;
    if (uncounted) {
        self.out.e.op(jit::SLJIT_LSHR, jit::reg_r(3), jit::reg_r(0), 0, jit::SLJIT_IMM, 48);
        self.out.guard(jit::SLJIT_EQUAL, jit::reg_r(3), 0, jit::SLJIT_IMM, (long)types::TAG_STRING, pc);
    }
    self.store(reg, pc, uncounted);
}
