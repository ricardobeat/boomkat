// Optimizing tier: the graph.
//
// A function is built into blocks of nodes in reverse postorder, which is also
// the order the code is emitted in. Every JS register is, at each point,
// either Window (its value lives only in the interpreter's register window and
// its type is not known) or a numeric node, INT32 or FLOAT64, in a machine
// register or a constant. A node is dirty while the window slot of the
// register that holds it is stale. Everything that is not numeric is done by
// GENERIC nodes: the baseline emitter's code on the window, run after the
// dirty registers it can read are stored.
//
// A node's "home" is the window slot of the register it was defined into. No
// node is held by two registers, so a register's slot is only ever the home of
// the node that register currently holds.
//
// VALUE nodes: a boxed value in a machine register, such as a property read whose result is used
// as the receiver of another field access: an object, an inert value such as null, or a string a
// load read from a counted holder (OptNode.counted); never a bigint or a string that publication
// would have to queue. A string a counted holder lets go of is queued then (Heap.decref), and only
// a safepoint frees queued strings, so the window slot it is stored to before one keeps it. The
// collector reads only the window, so the invariant that keeps it sound is: a VALUE node is
// created only while incremental marking is off (else the load leaves for the baseline code,
// which shades what it publishes), and it is stored to its home slot, raising the frame's
// heap_reg_count as Asm.publish does, before anything that can collect or inspect the window
// runs: a GENERIC node, an exit, a back edge's poll (a loop header holds no VALUE node: the
// registers that reach one are stored on the edge; a forward join gives the nodes that differ a
// phi) and any node that reads the window slot (STORE_VALUE). Marking cannot begin in between, as only those points can allocate or call. A
// node that finds no machine register lives in its home slot from its definition on, as the
// numeric ones do.
//
// The exception is a VALUE node of an inlined body whose home slot lies beyond the caller's
// frame (slot >= the caller's num_regs): the collector does not scan it, and no pop sweeps it,
// until an exit publishes the callee's frame. The body is a leaf (no GENERIC, no allocation, no
// loop; its calls are inlined bodies in turn), so its exits are the only points that can collect,
// and an exit stub stores the live nodes and calls jit_inline_materialize at once, which publishes
// the frames covering the slot. The callee and receiver of a nested call, register copies and
// returns into such slots are VALUE nodes of this kind too. Such a
// node therefore lives in a machine register only: it is never stored in the normal flow. The
// builder refuses the inline for a STORE_VALUE of it or an edge store of it, the allocator never
// spills it (the function is then built without inlining), and its load exits instead of
// publishing while the collector is marking.
//
// A boolean a comparison or `!` computes is a VALUE node as well (OptGraph.is_boolean). No
// collector reads it and no store counts it, so none of the above binds it: it is stored to any
// slot, plainly.
//
// An inlined NEW_OBJ allocates (OptOp.NEW_OBJECT) and its constructor body may call the put-absent
// helper (OptOp.ADD_FIELD). Neither is a point that can collect: the heap's allocators only request
// a collection for the next safepoint (Heap.request_gc), and a new object is a temporary root and
// is shaded while marking (Heap.adopt_object), so it may live in a register like any VALUE node,
// and the windows beyond the caller's frame need no scan extent. Such a call clobbers the scratch
// registers, so the machine registers that hold values across it are saved in the frame around it
// (OptCg.spill_live). The object is a VALUE node homed in the receiver slot of the NEW_OBJ, the
// constructor's `this`, where an exit from the body stores it for the frame it publishes.
//
// Allocation sinking (opt_sink.c3): a NEW_OBJECT whose object only flows through COPY nodes into
// the receivers of field accesses, the receiver of an inlined call and the dirty registers of exits
// is not allocated at all. Its nodes are `sunk` (no register, no code), its fields are the nodes
// stored into them, and every exit that can see it allocates it with the fields it has there
// (OptMat) and stores it to each slot that holds it, before the frames are published. The exit is
// the only collecting point such an object meets, and its allocation does not collect either.
module boomkat::jit @feat(SLJIT);

import boomkat::bytecode;
import boomkat::hobject;
import boomkat::types;
import boomkat::vm;
import std::collections::list;
import std::io;

const uint NO_NODE = uint::max;

enum OptRep : char {
    NONE,
    // A sign-extended 64-bit register holding a value in int32 range.
    INT32,
    // A double in a floating point register.
    FLOAT64,
    // A boxed value in a machine register (see the invariant above).
    VALUE,
}

enum OptOp : char {
    // imm is the value: an int32, or the bits of a double.
    CONST_I32,
    CONST_F64,
    // The boxed object imm a GETGLOBAL or GETCAP read from a binding the code folded
    // (OptBuild.fold_binding): a VALUE node with no register and no home, as the numeric constants
    // are. A GUARD_BINDING before it in its stretch of code proves the binding holds it.
    CONST_OBJ,
    // Window slot imm, checked to hold an int32 (exit NOT_INT32) or a number
    // (exit NOT_NUMBER), as an INT32 or FLOAT64.
    CHECK_I32,
    CHECK_NUM,
    // A GETCAP (imm its pc) read as a number of the node's rep; exits when the capture is not
    // one of the plain cases or not that kind of number. In a nested inlined body b is the VALUE
    // node holding the callee's closure, when its register lies beyond the caller's frame.
    LOAD_CAP,
    // A GETPROP (imm its pc) of the dense or typed array element at INT32 node a, as a number of
    // the node's rep; exits for any other object, an index out of range, a hole or another value.
    LOAD_ELEM,
    // A PUTPROP (imm its pc) of node b (a number, or a VALUE node stored through the barrier) or
    // of the window value when b is NO_NODE, to the element at INT32 node a, exiting where LOAD_ELEM
    // would. It defines nothing.
    STORE_ELEM,
    // A GETPROPC, GETPROPC_CACHED or GETTHISC (imm its pc) read of the own data property its
    // cache names, from a non-proxy object of the cache's shapes; exits for any other receiver. The
    // receiver is the VALUE node b, or the window register when b is NO_NODE. Of rep NONE it writes
    // the value to the window, of rep VALUE it leaves it in a register (exiting when the value is
    // a string or another counted value, or incremental marking runs), else it is a number of the
    // node's rep.
    LOAD_FIELD,
    // A GETPROPC or GETPROPC_CACHED (imm its pc) of `length` from an array, as an INT32; exits
    // (SLOW_PATH) for any other receiver or a length above the int32 range. The receiver is the
    // VALUE node b, or the window register when b is NO_NODE.
    LOAD_LENGTH,
    // A PUTPROPC or PUTTHISC (imm its pc) overwrite of the own writable data property its cache
    // names, in a plain object of the cache's shape; exits for any other receiver or a value that
    // needs a barrier. a is the number or VALUE node stored, the STORE_CONST whose constant the
    // value's slot holds, or NO_NODE for a value in the window; b the VALUE node receiver, or
    // NO_NODE for the window. It defines nothing.
    STORE_FIELD,
    PHI,
    // The VALUE node a, stored to its home window slot imm (the register) and now clean; for the
    // window readers that cannot take a node (a branch, an element access, a call).
    STORE_VALUE,
    // A new node holding the value of `a`.
    COPY,
    // INT32 operands a, b. These exit (OVERFLOW) on a result out of int32 range;
    // MUL also on -0.
    ADD_I32,
    SUB_I32,
    MUL_I32,
    AND_I32,
    OR_I32,
    XOR_I32,
    NOT_I32,
    // b is the count, masked to five bits.
    SHL_I32,
    SAR_I32,
    // `>>>`: exits (OVERFLOW) when the result is above the int32 range.
    SHR_I32,
    // INT32 operands a, b: a % b for a >= 0 and b > 0, else it exits (OVERFLOW), so no result is
    // -0 or NaN.
    MOD_I32,
    I32_TO_F64,
    // JS ToInt32 of a double; exits when the double is not within int64 range.
    F64_TO_I32,
    ADD_F64,
    SUB_F64,
    MUL_F64,
    DIV_F64,
    NEG_F64,
    // A call site's inlined callee (imm its CompiledFunction*, the call at pc, cc nonzero for a
    // method call): exits (CALLEE) before any effect unless the callee register holds a closure of
    // that function, the receiver and the frame a real call would publish are acceptable, and
    // there is room for it. The nodes after it, until the next such node, are the callee's body.
    // a and b, when not NO_NODE, are VALUE nodes holding the callee and the receiver (a nested
    // call whose window lies beyond the caller's frame). Before a CALL_REG of a polymorphic call,
    // imm is 0 and poly names the functions any of which passes.
    CHECK_CALLEE,
    // The variable a CALL_VAR (cc nonzero) or CALL_GLOBAL (imm its pc) names, stored in the call's
    // callee register as a published value; exits (SLOW_PATH) when its cache does not hold. Of
    // rep VALUE (a callee register beyond the caller's frame) it stays in a register.
    LOAD_VAR,
    // A GETGLOBAL of an inlined body (imm its pc) read as a number of the node's rep; exits when
    // its cache does not hold or the value is not that kind of number.
    LOAD_GLOBAL,
    // Exits (BINDING) before the GETGLOBAL or GETCAP at pc unless the binding OptGraph.bindings[imm]
    // still holds the value the code folded, the backing store of a typed array value included: with
    // cc bit OPT_GUARD_LAYOUT first its holder's layout, with OPT_GUARD_EPOCH the folded-object epoch
    // (OptBinding). While the collector marks, an object value is shaded, as a load of it would be.
    // It defines nothing.
    GUARD_BINDING,
    // Exits (CAPTURE) before the GETCAP at pc unless the running closure's capture record is
    // OptGraph.captures[imm]: the binding of a holder the code folds from, or a snapshot of the
    // value it folds. Nothing changes a record a frame has proven, so one guard serves the frame.
    // It defines nothing.
    GUARD_CAPTURE,
    // The window slot imm (a callee RET's register) copied to the window slot home (the call's
    // result register) as a published store; exits (SLOW_PATH) where publish does. cc 1 copies
    // the receiver slot of the inlined call (LDTHIS), cc 2 register B of the instruction (LDREG),
    // cc 3 the graph register imm itself (a forwarded argument, OptBuild.forward_window), cc 4 the
    // function's own receiver (its record's this_binding).
    // Of rep VALUE the value stays in a register (finish_value), for a home beyond the
    // caller's frame.
    COPY_WINDOW,
    // The boxed constant imm (undefined, null or a boolean) stored to the window slot home.
    STORE_CONST,
    // A TYPEOF of an inlined body: the interned builtin name (heap.strs) of the value in the VALUE
    // node a, or in the window slot imm when a is NO_NODE, stored to the window slot home. cc 1 is a
    // numeric operand, whose name is `number` with no test. The names are the heap's own strings,
    // which no collection reclaims, so slot home may lie beyond the caller's frame (see the header).
    TYPEOF,
    // A NEWOBJ, NEWOBJ_SHAPE, NEWARR or NEWARR_CONST (pc) of an inlined body, allocated inline as the
    // baseline emitter allocates it and stored boxed to the window slot home. The allocator adopts
    // the object as a temporary root, and the only points that can collect are exits, which publish
    // the frames covering the slot (see the header of this file), so home may lie beyond the
    // caller's frame. A case the inline allocator does not cover, and a failed allocation, exits
    // (ALLOC_SLOW) with nothing changed to the baseline code at pc.
    ALLOC,
    // An INIT_SLOT (imm its pc) of an inlined body: the value of the number or VALUE node a, or of
    // window slot c when a is NO_NODE, stored into prop_values()[b] of the object that node b holds,
    // or of window slot a when b is NO_NODE. It defines nothing and exits (SLOW_PATH) where the
    // store needs a counted or traced path.
    INIT_SLOT,
    // The boolean (a VALUE node) of numbers a, b of rep imm compared by the JMP_* row cc (as
    // BRANCH reads it).
    COMPARE,
    // The boolean (a VALUE node) of the equality test of BRANCH_WINDOW (cc 0 SEQ, 1 SNEQ, 2 EQ,
    // 3 NEQ, 4 == null, 5 != null, and the constant of WINDOW_CONST) of the VALUE nodes a and b, or
    // where either is NO_NODE of its window slot of imm (b | c << 20); the rare cases exit through
    // the slow path.
    COMPARE_WINDOW,
    // `!` of node a, a boolean (a VALUE node); or, when a is NO_NODE, of the window slot imm,
    // stored to window slot home. The slow path of a value of unknown kind exits.
    LNOT,
    // A CALL (pc) of Array.prototype.push, after the CHECK_BUILTIN of its callee: the value a (a
    // node, or the window slot after the receiver when NO_NODE) appended to the array b (a VALUE
    // node, or the receiver's window slot), growing its storage without a collection; the new
    // length as an INT32. Exits (SLOW_PATH) before any effect for anything but an extensible plain
    // array with a writable length on the built-in prototype chain.
    ARRAY_PUSH,
    // A call of a Math function (OptMath imm) on the numbers a and b (b: NO_NODE but for two
    // arguments), after the CHECK_BUILTIN of its callee. INT32 for ABS, MIN and MAX of INT32
    // operands, where ABS exits (OVERFLOW) at -2^31; FLOAT64 otherwise.
    MATH,
    // An unconditional exit (COLD) to the baseline code at pc, with the dirty registers stored: an
    // instruction of an inlined body that has never run, or with cc OPT_EXIT_LEAVE a region's branch
    // out of its loop, which leaves without counting as an exit. The block has no successors.
    EXIT,
    // A jump to succ[0]; a conditional branch (BRANCH: JMP_* row cc over a and b
    // of rep imm, BRANCH_TRUTH: IF_TRUE/IF_FALSE over a, or the window slot imm
    // when a is NO_NODE, cc nonzero for IF_FALSE) takes succ[0] when it holds and
    // falls to succ[1].
    JUMP,
    BRANCH,
    BRANCH_TRUTH,
    // A branch by the baseline's equality test of the VALUE nodes a and b, or where either is
    // NO_NODE of its window slot of imm (b | c << 20): cc is 0 JMP_SEQ, 1 JMP_SNEQ, 2 JMP_EQ,
    // 3 JMP_NEQ, 4 JMP_NULL, 5 JMP_NNULL. A strict test against a constant the builder stored
    // (WINDOW_CONST in the bits above) compares the first operand with it alone.
    BRANCH_WINDOW,
    // The test before a case of a polymorphic call (OptBuild.callee_test): falls to succ[1], the
    // case's body, when the VALUE node a, or the window slot of the call's callee register when a
    // is NO_NODE, holds a closure of the function imm (its CompiledFunction*); else takes succ[0].
    BRANCH_CALLEE,
    // The bytecode instruction at pc, through the baseline emitter.
    GENERIC,
    // The call at pc of key (its CompiledFunction), CHECK_CALLEE before it: the window stored as a
    // GENERIC's, the callee entered through its register label (OptCg.emit_call_reg), its result
    // stored to the window. A null key is a polymorphic call, of the function the callee holds. The caller's registers survive the call; it exits at the call when the
    // callee has no call entry (DECLINED) or declines (DEEP).
    CALL_REG,
    // A NEW_OBJ (pc) of the constructor imm (its CompiledFunction*), after its CHECK_CALLEE: a plain
    // object with the prototype the instruction's cache reads from the constructor, the VALUE node
    // the inlined body takes as `this`. Exits (ALLOC_SLOW) before any effect when the constructor is
    // not constructable, the cache does not hold or the allocation fails. a, when not NO_NODE, is the
    // VALUE node holding the constructor. Sunk, it allocates nothing: c is its OptGraph.sinks
    // entry, and it exits where the allocation would unless the state its site validated holds.
    NEW_OBJECT,
    // The guard of an inlined forwarding call (`f.apply(x, arguments)`, OptBuild.forward_window):
    // exits (CALLEE) unless the VALUE node a, or the window slot home when a is NO_NODE, holds the
    // builtin function numbered imm. It defines nothing.
    CHECK_BUILTIN,
    // Window slot imm moved to window slot home within the caller's frame, as the interpreter moves
    // the registers of a forwarding call: a value the frame already holds, so it only raises the
    // frame's heap-register count. It never exits and defines nothing.
    MOVE_WINDOW,
    // A PUTTHISC (imm its pc) of an inlined constructor that adds its key to the VALUE node b through
    // the instruction's absent-property cache, as the baseline's put-absent path; a is the number or
    // VALUE node stored, or NO_NODE for a value in the window. Exits before any effect when the add
    // is not one the cache describes. It defines nothing. With cc 1 the object is one the code is
    // building (OptFresh) and the add is known: the value goes into the next slot and the object
    // takes the shape `shape`, with only a value that is neither inert nor an object (from the
    // window, or a node that may hold a string) taking the cache. The NEW_OBJECT validated every such key against the prototype chain.
    ADD_FIELD,
    // A field access of a sunk object, done in the graph: no code. Its dirty registers stay for the
    // exit the test hook may force there.
    SUNK,
}

// The equality nodes' cc: the test in the low bits, and in the bits from WINDOW_CONST_SHIFT the
// constant of a strict test against undefined, null or a boolean (window_const_bits), or 0.
const char WINDOW_KIND_MASK = 7;
const char WINDOW_CONST_SHIFT = 3;

// LOAD_ELEM and STORE_ELEM cc: an earlier access proved the receiver an array (OptBuild.elem_fact),
// so no class is tested.
const char ELEM_KNOWN = 1;
// What element accesses proved of a register's object (OptBuild.fact_elem): an array, and an
// array without indexed named properties, which a store needs.
const char ELEM_ARRAY = 1;
const char ELEM_ARRAY_STORE = 2;

// The boxed constant of a WINDOW_CONST id: 1 undefined, 2 null, 3 false, 4 true.
fn long window_const_bits(char id) {
    switch (id) {
        case 1: return K_UNDEF;
        case 2: return K_NULL;
        default: return K_BOOL | (long)(id - 3);
    }
}

// The WINDOW_CONST id of boxed constant `bits` (undefined, null or a boolean).
fn char window_const_id(long bits) {
    if (bits == K_UNDEF) return 1;
    if (bits == K_NULL) return 2;
    return (char)(3 + (bits & 1));
}

// A window slot and the node whose value belongs in it.
struct OptDirty {
    uint reg;
    uint node;
}

// A function whose bytecode appears in the graph: fns[0] is the function being optimized, the
// others are inlined callees. A callee's registers are the caller's, shifted by reg_base: callee
// register r is register reg_base + r of the graph.
struct OptFn {
    CompiledFunction* f;
    uint reg_base;
    // For an inlined callee: the word of the caller after the call, where the caller resumes once
    // the callee frame that an exit from the body publishes returns.
    uint resume_pc;
    // The callee word whose result register is remap_reg of the caller, instead of its own
    // register (uint::max when none).
    uint remap_pc;
    uint remap_reg;
    // The entry whose body holds the call (0 for the function being optimized), how many
    // inlined calls deep this body is, and the registers of that caller's frame (by its own
    // numbering) an exit from this body keeps when it publishes the caller's frame too.
    uint parent;
    uint depth;
    uint parent_keep;
    // The count of arguments the inlined call passes.
    uint nargs;
}

struct OptNode {
    OptOp op;
    OptRep rep;
    char cc;
    uint a;
    uint b;
    // LOAD_ELEM, STORE_ELEM: the VALUE node holding the receiver, else NO_NODE for the window.
    uint c;
    long imm;
    // The bytecode word the node came from; an exit resumes there.
    uint pc;
    // The OptGraph.fns entry whose bytecode pc and imm (for the nodes that carry one) index.
    uint fidx;
    // The dirty registers live at the node: an exit stores them, a GENERIC
    // stores them before it runs.
    uint dirty_first;
    uint dirty_count;
    // GENERIC: the numeric registers live after it, reloaded from the window.
    uint reload_first;
    uint reload_count;
    // Inside an inlined callee: the callee registers (bit r for callee register r) live at the
    // node, which the callee frame an exit publishes must keep.
    uint live_mask;
    // LOAD_FIELD, STORE_FIELD: 1 + the index in OptGraph.polys of the receiver shapes it accepts.
    // CHECK_CALLEE of a polymorphic call: 1 + the index in OptGraph.callees of its functions.
    uint poly;
    // The window slot a node was defined into.
    uint home;
    // Allocation: the machine register, or -1 for a constant or a value that
    // lives in its home slot.
    int reg;
    // The last node position that uses this value.
    uint last_use;
    // The field key of a LOAD_FIELD, STORE_FIELD or ADD_FIELD (an interned string).
    void* key;
    // A known ADD_FIELD (cc 1): the shared shape it leaves the object in.
    uint shape;
    // A NEW_OBJECT, or a COPY of one, whose object is not allocated (c names its sink).
    bool sunk;
    // A field value of a sunk object, which an exit stores into it: kept in a register.
    bool held;
    // An inherited LOAD_FIELD (cc 2) whose entry has only ever held one receiver shape: any other
    // exits (OptExit.RECEIVER), so the read proves the shape as an own one does.
    bool exact;
    // A VALUE node that may hold a string (read from a counted holder by a load, or a copy or phi
    // of one), which a store into the heap counts. Any other VALUE node holds no counted value.
    bool counted;
}

// A sunk allocation: its NEW_OBJECT node, the keys its fields are added under, in order, and the
// keys read from its prototype chain. `site` is the run-time OptSinkSite the emitter made.
struct OptSink {
    uint node;
    uint add_count;
    uint read_count;
    void*[OPT_SINK_FIELDS] keys;
    void*[OPT_SINK_READS] reads;
    void* site;
}

// An exit at `node` that allocates sunk object `sink` with its first `count` fields, the values
// mat_vals[vals_first ..].
struct OptMat {
    uint node;
    uint sink;
    uint count;
    uint vals_first;
}

// An edge's work: a phi receives `src`, converted when its rep differs; with
// dst NO_NODE the dirty value `src` is stored to window slot `slot`.
struct OptMove {
    uint dst;
    uint src;
    uint slot;
}

struct OptBlock {
    // Node positions [first, end).
    uint first;
    uint end;
    // The bytecode word of the first instruction.
    uint pc;
    uint succ_count;
    uint[2] succ;
    // The moves of each outgoing edge: [first, first + count) in OptGraph.moves.
    uint[2] move_first;
    uint[2] move_count;
    bool header;
    // The last block position of the loop this block heads.
    uint loop_end;
    // For a header: the phis' (register, node) pairs, which a poll's exit stores.
    uint entry_first;
    uint entry_count;
    // Entered from baseline code (the target of a backward branch): the numeric
    // nodes live at its start, which the entry reloads from the window.
    bool osr;
    uint osr_first;
    uint osr_count;
    // What the code of an OSR entry's loop assumes at its start, which the entry proves: the
    // objects of [fact_first, fact_first + fact_count) in OptGraph.entry_facts, and the bits of
    // OptBuild.fact_bindings and fact_captures.
    uint fact_first;
    uint fact_count;
    ulong bindings;
    ulong captures;
}

// The register (OPT_THIS: `this`) whose object a loop's code assumes of the shape `shape` (unless
// SHAPE_NONE), plain as well when `plain`, and an array as `elem` says (OptBuild.fact_elem).
struct OptEntryFact {
    uint reg;
    uint shape;
    bool plain;
    char elem;
}

const uint OPT_THIS = uint::max;

// The distinct receiver shapes one field site's code compares: as many as the baseline cache can
// record in an entry (hobject::IC_POLY_MAX), since a longer chain has nothing to compare against.
// Each case costs a 32-bit compare and a slot load, and eight bytes in the node and the
// register-pressure estimate.
const uint OPT_POLY_MAX = hobject::IC_POLY_MAX;

// The receiver shapes a field access accepts, in the order its code compares them, each with the
// slot its property has in an object of that shape.
struct OptPoly {
    uint count;
    uint[OPT_POLY_MAX] shape;
    uint[OPT_POLY_MAX] idx;
}

// An object that holds bindings the code folds: the global object, or the scope or cell a captured
// binding lives in. Its values stay where they are while its shape is `shape` and that shape's
// storage `gen`: a property added in place keeps both, and anything that moves or reorders the values
// changes one.
struct OptHolder {
    HObject* obj;
    uint shape;
    uint gen;
}

// A binding whose value the code folds (OptBuild.fold_binding): a `var` or function declaration,
// which nothing can delete, make an accessor or shadow, at `slot` of holder `holder`; or a
// captured value snapshot (OPT_NO_HOLDER, no slot), which nothing writes. An object value is marked
// folded, so that its death moves Heap.folded_epoch from OptGraph.folded_epoch before its address
// can name another object.
struct OptBinding {
    uint holder;
    hobject::PropValue* slot;
    ulong value;
}

const uint OPT_NO_HOLDER = uint::max;

// The capture record `index` of the closure the code folds captured bindings of: its two words, the
// owner or value snapshot, then the index and kinds (hobject::CaptureRef).
struct OptCapture {
    uint index;
    ulong[2] words;
}

// GUARD_BINDING's cc bits.
const char OPT_GUARD_LAYOUT = 1;
const char OPT_GUARD_EPOCH = 2;

// A join (block `pos` in reverse postorder) and a register merged there.
// The function of a MATH node, with the number of arguments its call passes.
enum OptMath : char (uint args) {
    ABS {1},
    FLOOR {1},
    CEIL {1},
    ROUND {1},
    SQRT {1},
    MIN {2},
    MAX {2},
    POW {2},
    SIN {1},
    COS {1},
    TAN {1},
    EXP {1},
    LOG {1},
    ATAN {1},
    ATAN2 {2},
}

// OptNode.cc of an EXIT that leaves a region (OptOp.EXIT).
const char OPT_EXIT_LEAVE = 1;

struct OptJoin {
    uint pos;
    uint reg;
}

fn bool opt_join_windowed(List{OptJoin}* joins, uint pos, uint reg) {
    foreach (j : *joins) if (j.pos == pos && j.reg == reg) return true;
    return false;
}

// A loop compiled without the rest of its function: the words [start, end), entered only at the
// loop headers in them, and left for the baseline code at every branch out. `regs` is the window of
// the frame whose back edge asked for it, which the header's phis speculate on; it is read only
// while building. An `end` of 0 is the whole function.
struct OptRegion {
    uint start;
    uint end;
    TVal* regs;
}

// The functions the callee of a polymorphic register call may be a closure of (OptNode.poly).
struct OptCallees {
    CompiledFunction*[hobject::IC_CALL_TARGETS] fns;
    uint count;
}

struct OptGraph {
    OptRegion region;
    List{OptPoly} polys;
    List{OptCallees} callees;
    List{OptNode} nodes;
    List{OptBlock} blocks;
    List{OptMove} moves;
    List{OptDirty} dirty;
    List{OptFn} fns;
    List{OptSink} sinks;
    List{OptMat} mats;
    List{uint} mat_vals;
    List{OptHolder} holders;
    List{OptBinding} bindings;
    List{OptCapture} captures;
    List{OptEntryFact} entry_facts;
    // Heap.folded_epoch when the graph was built.
    uint folded_epoch;
    // The frame whose entry or loop asked for the compile, or null; its closure's capture records,
    // once a GETCAP is lowered (OptBuild.frame_refs).
    Activation* frame;
    CaptureRef* refs;
    bool refs_read;
}

fn void OptGraph.init(&self) {
    self.sinks.init(mem);
    self.mats.init(mem);
    self.mat_vals.init(mem);
    self.holders.init(mem);
    self.bindings.init(mem);
    self.captures.init(mem);
    self.entry_facts.init(mem);
    self.polys.init(mem);
    self.callees.init(mem);
    self.nodes.init(mem);
    self.blocks.init(mem);
    self.moves.init(mem);
    self.dirty.init(mem);
    self.fns.init(mem);
}

fn void OptGraph.clear(&self) {
    self.sinks.clear();
    self.mats.clear();
    self.mat_vals.clear();
    self.holders.clear();
    self.bindings.clear();
    self.captures.clear();
    self.entry_facts.clear();
    self.polys.clear();
    self.callees.clear();
    self.nodes.clear();
    self.blocks.clear();
    self.moves.clear();
    self.dirty.clear();
}

fn void OptGraph.free(&self) {
    self.sinks.free();
    self.mats.free();
    self.mat_vals.free();
    self.holders.free();
    self.bindings.free();
    self.captures.free();
    self.entry_facts.free();
    self.polys.free();
    self.callees.free();
    self.nodes.free();
    self.blocks.free();
    self.moves.free();
    self.dirty.free();
    self.fns.free();
}

fn bool OptNode.is_const(&self) @inline => self.op == OptOp.CONST_I32 || self.op == OptOp.CONST_F64 || self.op == OptOp.CONST_OBJ;

// Whether VALUE node `n` holds a boolean: a comparison, a `!`, a phi of such (cc 1), or a copy.
fn bool OptGraph.is_boolean(&self, OptNode* n) {
    while (n.op == OptOp.COPY) n = &self.nodes[n.a];
    if (n.rep != OptRep.VALUE) return false;
    return n.op == OptOp.COMPARE || n.op == OptOp.COMPARE_WINDOW || n.op == OptOp.LNOT || (n.op == OptOp.PHI && n.cc == 1);
}

// Whether a node of this rep lives in an integer register.
fn bool OptRep.is_gpr(self) @inline => self == OptRep.INT32 || self == OptRep.VALUE;

// Print the graph to stderr: one line per node, with the register allocation
// and the moves of each edge.
fn void OptGraph.dump(&self, CompiledFunction* f) {
    io::eprintfn("opt graph: fn#%d %s: %d nodes, %d blocks, code %d words", f.func_index, (String)f.name_ptr[:f.name_len], self.nodes.len(), self.blocks.len(), f.code_count);
    for (uint i = 1; i < self.fns.len(); i++) {
        io::eprintfn("inline fn=%d cf=fn#%d base=%d resume=%d parent=%d depth=%d", i, self.fns[i].f.func_index, self.fns[i].reg_base, self.fns[i].resume_pc, self.fns[i].parent, self.fns[i].depth);
    }
    foreach (pos, &blk : self.blocks) {
        io::eprintfn("block %d pc=%d%s succ=[%d %d] n=%d", pos, blk.pc, blk.header ? " loop-header" : "", blk.succ[0], blk.succ[1], blk.succ_count);
        for (uint i = blk.first; i < blk.end; i++) {
            OptNode* n = &self.nodes[i];
            if (n.op == OptOp.GENERIC) io::eprintf("  [%s]", self.fns[n.fidx].f.code[(uint)n.imm].op);
            io::eprintf("  n%d %s rep=%s a=%d b=%d imm=%d pc=%d reg=%d home=%d last=%d cc=%d", i, n.op, n.rep, (int)n.a, (int)n.b, n.imm, n.pc, n.reg, n.home, n.last_use, n.cc);
            if (n.fidx != 0) io::eprintf(" fn=%d", n.fidx);
            if (n.sunk) io::eprintf(" sunk=%d", n.c);
            if (n.dirty_count != 0) {
                io::eprintf(" dirty=");
                for (uint k = 0; k < n.dirty_count; k++) io::eprintf("r%d:n%d ", self.dirty[(sz)(n.dirty_first + k)].reg, self.dirty[(sz)(n.dirty_first + k)].node);
            }
            if (n.reload_count != 0) {
                io::eprintf(" reload=");
                for (uint k = 0; k < n.reload_count; k++) io::eprintf("r%d:n%d ", self.dirty[(sz)(n.reload_first + k)].reg, self.dirty[(sz)(n.reload_first + k)].node);
            }
            io::eprintfn("");
        }
        for (uint e = 0; e < blk.succ_count; e++) {
            for (uint k = 0; k < blk.move_count[e]; k++) {
                OptMove m = self.moves[(sz)(blk.move_first[e] + k)];
                io::eprintfn("  edge%d -> b%d: dst=%d src=%d slot=%d", e, blk.succ[e], (int)m.dst, (int)m.src, m.slot);
            }
        }
    }
}
