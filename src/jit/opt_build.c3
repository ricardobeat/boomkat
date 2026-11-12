// Optimizing tier: building the graph from the bytecode.
//
// The function's control flow graph is ordered in reverse postorder and built
// in one pass in that order, keeping for each JS register either Window or a
// numeric node (see opt_ir.c3). A merge makes a phi only where every
// predecessor holds a numeric node. A loop header speculates its phis from the
// states that reach it from before the loop, and the build starts over, with
// the choice overridden, when a back edge disagrees.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::builtins;
import boomkat::bytecode;
import boomkat::compiler;
import boomkat::env;
import boomkat::features;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import std::collections::list;
import std::io;

// Largest graph a function may build into, and the rounds of loop repair.
const uint OPT_BLOCK_MAX = 1024;
const uint OPT_STATE_MAX = 256 * 1024;
const uint OPT_BUILD_ROUNDS = 5;
const uint OPT_BUILD_ROUNDS_MAX = 16;
// The words of a region (OptRegion), and the whole function's graph whose liveness its exits read.
const uint OPT_REGION_WORDS_MAX = 8192;
const compiler::DecodedCfgBudget OPT_REGION_CFG_BUDGET = { OPT_REGION_WORDS_MAX, OPT_REGION_WORDS_MAX, 2 * 1024 * 1024 };
const compiler::DecodedCfgBudget OPT_REGION_LIVENESS_BUDGET = { 65536, 65536, 16 * 1024 * 1024 };

// A loop phi's decision, overriding the speculation from the preheader.
struct OptOverride {
    uint block;
    uint reg;
    OptRep rep;
    // A VALUE rep asked only to keep a read out of a window slot beyond the caller's frame
    // (OptBuild.get_field), which a numeric use may still turn into its own rep.
    bool soft;
}

struct OptRegState {
    uint node;
    bool dirty;
}

// A field value the code holds: field `key` of the VALUE node `recv` (the root of its copies), or
// of window register `reg` when recv is NO_NODE (reg is NO_NODE otherwise), last read into or
// stored from `node`.
struct OptAvail {
    void* key;
    uint recv;
    uint reg;
    uint node;
}

const uint OPT_AVAIL_MAX = 8;

// An object an inlined NEW_OBJECT allocated whose shape the code knows: the shape its adds have
// left it in, how many properties it has and its inline capacity. While nothing that can run code
// or reach another block has been built since (OptBuild.add), an add of a key that a shared
// transition takes from that shape is a store into its next slot (OptBuild.add_field).
struct OptFresh {
    uint node;
    uint shape;
    uint count;
    uint capacity;
}

const uint OPT_FRESH_MAX = 4;

fn bool OptAvail.same(self, OptAvail o) => self.key == o.key && self.recv == o.recv && self.reg == o.reg && self.node == o.node;

// Why a function was not optimized.
enum OptRefuse : char (String label) {
    NONE {"none"},
    FUNCTION {"function kind"},
    CFG {"control flow graph"},
    OPCODE {"opcode"},
    IRREDUCIBLE {"irreducible loop"},
    BUDGET {"graph size"},
    REPAIR {"loop repair rounds"},
    PRESSURE {"phi register pressure"},
    BRANCH_OPERANDS {"branch operands"},
    COMPILE {"code generation"},
}

// Why a field instruction was left to the baseline instead of being lowered (--jit-stats).
enum OptFieldSkip : char (String label) {
    NO_CACHE {"no cache"},
    BANNED {"site banned"},
    PROTO {"inherited chain"},
    CHAIN {"chain not cached"},
    ABSENT {"absent or accessor"},
    LENGTH {"length"},
    KEY {"key is not the site constant"},
    POLY_FULL {"more shapes than compared"},
}

// Why a call site with a known callee is not inlined (--jit-stats counts them).
enum OptInlineReject : char (String label) {
    POLY {"polymorphic call"},
    WINDOW {"window beyond the caller's registers"},
    SELF {"recursive"},
    NO_JIT {"callee has no baseline code"},
    NO_JIT_TRIVIAL {"trivial callee has no baseline code"},
    INELIGIBLE {"callee not eligible"},
    NOT_LEAN {"callee not a lean call"},
    ARGS {"arguments or rest object"},
    SIZE {"callee too big"},
    TOP_LEVEL {"top level code"},
    WINDOW_LIVE {"call window live after the call"},
    BLOCKS {"loop in the callee"},
    WIDE {"wide instruction"},
    NO_RET {"no final return"},
    READ_UNDEF {"reads an unwritten register"},
    OPCODE {"opcode (see below)"},
    FEEDBACK {"arithmetic feedback not numeric"},
    FIELD {"field is not an own data field"},
    CONSTANT {"constant is not a number"},
    GLOBAL {"global not cached"},
    THIS {"this of a plain call"},
    BUILD {"body not lowerable at build"},
    UNSAFE {"heap value in the callee window"},
    STATE {"call state not usable"},
    DEPTH {"inlined calls nested too deep"},
    CTOR {"not a base constructor"},
    CTOR_BODY {"constructor body not straight-line"},
    NESTED_FLAT {"nested callee body not straight-line"},
    DOTCALL_FLAT {"function called through call has several blocks"},
    SPLICE {"callee body cannot be spliced"},
    BANNED {"an instruction of the callee exited repeatedly"},
}

// The words of bytecode an inlined callee may have, and the callees nested in one inline site may
// have together.
const uint INLINE_WORDS_MAX = 64;
const uint INLINE_TREE_WORDS_MAX = 200;

// A call site whose callee the graph may inline (OptBuild.find_sites): a straight-line body, found
// by the call's feedback, with its own control flow graph and liveness.
struct OptInlineSite {
    // The call's instruction in the caller's control flow graph.
    uint insn;
    CompiledFunction* cf;
    // Callee register r is graph register base + r: the window the call publishes.
    uint base;
    // A method call (CALL), whose receiver is the callee's `this`.
    bool method;
    // A NEW_OBJ: the callee's `this` is the object the inline allocates (OptOp.NEW_OBJECT), in the
    // receiver slot base - 1, and the result unless the body returns an object.
    bool construct;
    // CALL_VAR or CALL_GLOBAL, which load the callee from a variable.
    bool var_call;
    // The APPLY_ARGS of `f.apply(x, arguments)` in a forwarding body (forward_pair): the callee is
    // `f`, its receiver `x`, and its arguments those the forwarding body was called with.
    bool forward;
    // An `X.call(x, args)`: the callee register holds Function.prototype.call, the receiver slot
    // `X`, and the call runs `X` on `x` with the arguments after it (OptBuild.call_window shifts them
    // down as the builtin does). nargs counts the arguments after `x`.
    bool dotcall;
    // The count of arguments the call passes.
    uint nargs;
    DecodedCfg cfg;
    RegSet* live_in;
    RegSet* live_out;
    RegSet* live_sets;
    uint* live_words;
    // Per instruction: the callee registers written before it or arriving as arguments.
    uint* defined;
    // The instruction that writes the register the body returns, when it is the last before the
    // return and nothing else touches that register: it writes the call's result register
    // directly. uint::max when there is none.
    uint remap;
    // A build failure of this site is already counted in --jit-stats.
    bool counted;
    // A body with forward branches and several returns, or one holding such a call, which analyze
    // splices into the caller's control flow graph (OptBuild.flatten) instead of lowering in place:
    // the first of its instructions in that graph, the caller's pc of the outermost call of the
    // spliced tree (a failed build leaves that call a call), and the nodes' origin.
    bool flat;
    uint flat_off;
    uint head_pc;
    // The site whose callee's body holds this call plus one, or zero for a call of the function
    // being optimized; how many inlined calls deep the body is (1 for the latter); whether its
    // own body holds calls, and per callee instruction the nested site of each plus one.
    uint parent;
    uint depth;
    bool has_calls;
    uint* child_of;
    // One case of a polymorphic call (OptBuild.poly_sites): the body runs when the callee is a
    // closure of cf, after a test of the callee (fl_kind 5) that otherwise goes on to the next
    // case, poly_next minus one, or after the last to the call itself. Each case's body starts a
    // block of its own: the first test notes the read that put the callee in its register for all of
    // them (method_read, null when there is none).
    bool poly;
    uint poly_next;
    CompiledFunction* method_read;
    uint method_read_pc;
}

struct OptBuild {
    Heap* h;
    CompiledFunction* f;
    DecodedCfg cfg;
    RegSet* live_in;
    RegSet* live_out;
    uint* live_words;
    RegSet* live_sets;
    OptGraph* g;
    uint nregs;
    // Basic blocks by CFG block id: their instruction range.
    uint nb;
    uint* b_first;
    uint* b_last;
    // Reverse postorder: block at each position, and each block's position
    // (NO_NODE when unreachable).
    uint* rpo;
    uint* pos_of;
    uint nrpo;
    uint* pred_off;
    uint* pred_list;
    // Immediate dominators by position.
    uint* idom;
    uint* loop_end;
    // By instruction: the target of a backward branch.
    bool* osr_target;
    // A region's: the live-in set of each exit node, and the words they hold.
    RegSet* exit_in;
    uint* exit_words;
    // The caller's register count; nregs also covers the callee windows of the inline sites.
    uint caller_regs;
    // With flat sites, per instruction of the spliced graph: the flat site plus one whose body it
    // belongs to or zero, and for a body's last instructions how it returns: 1 a value, 2 undefined.
    uint* fl_site;
    uint* fl_kind;
    // Per instruction of the spliced graph in a flat body: its index in that body's own code.
    uint* fl_local;
    // Per site: the OptGraph.fns entry its head pushed in this round.
    uint* site_fn;
    uint flat_count;
    // Flat sites to leave as calls (by the caller's pc of the call), and why the last build was
    // abandoned: a flat body that could not be lowered, whose site is then excluded in a rebuild.
    uint* exclude;
    uint exclude_count;
    bool flat_fail;
    uint flat_fail_pc;
    // A flat body that failed to lower in this round (its site and why): it only counts once the
    // round is done and no typed load was requested, which would build the round again.
    bool flat_pend;
    uint flat_pend_site;
    OptInlineReject flat_pend_why;
    // The round is to be built again whatever it holds.
    bool void_round;
    // Per block position, in this round: the block ends in an unconditional exit (OptOp.EXIT) or
    // is reachable only through such blocks. It has no successors in the graph.
    bool* dead;
    // The instruction just lowered was an unconditional exit, and the head pc of its flat site.
    bool cold_exit;
    uint cold_site;
    List{OptInlineSite} sites;
    // By caller instruction: its inline site plus one, or zero.
    uint* site_of;
    // While an inlined body is lowered: its site.
    uint cur_site;
    // Set by an inlined body that cannot be built as straight-line numeric nodes, and by one that
    // would leave a heap value in a window slot outside the caller's frame; the call then stays a call.
    bool inline_failed;
    bool inline_unsafe;
    bool no_inline;
    // Calls of builtins built as nodes: ARRAY_PUSH, MATH.
    uint builtin_calls;
    // Calls entering their callee's direct label (direct_callee).
    uint direct_calls;
    // Why the last inline_candidate refused (set with the opcode in rej_op for OPCODE), and the
    // call it was looking at, for --opt-log: the caller, its call word and the callee once known.
    OptInlineReject rej;
    CompiledFunction* rej_caller;
    CompiledFunction* rej_callee;
    uint rej_pc;
    Opcode rej_op;
    uint inlined;
    OptRegState* cur;
    // Per JS register, and at index nregs for `this`: the shape id of the object it holds when the
    // last LOAD_FIELD or STORE_FIELD on it passed its guards and nothing since can have changed
    // that, else SHAPE_NONE; and whether that node also proved the object plain (a load only proves
    // it is not a proxy, which is all a load needs).
    uint* fact_shape;
    bool* fact_plain;
    // Per register: what the element accesses since the facts were last dropped proved of the
    // object it holds (OptBuild.elem_fact): ELEM_ARRAY, or ELEM_ARRAY_STORE (an array without
    // indexed named properties); 0 for nothing. An array never changes class.
    char* fact_elem;
    // What GUARD_BINDING nodes have proven since the last node that runs code (the bits after
    // OPT_BINDINGS_MAX), and the capture records GUARD_CAPTURE nodes have proven, by index, which
    // no code changes in a frame.
    ulong fact_bindings;
    ulong fact_captures;
    // The field values the code holds, kept and dropped with the facts: a later read of one takes
    // the node instead of the object (OptBuild.held_field).
    OptAvail[OPT_AVAIL_MAX] avail;
    uint avail_n;
    // The objects being built whose shape the code knows.
    OptFresh[OPT_FRESH_MAX] fresh;
    uint fresh_n;
    // The pc of the GETCAP or GETPROP, still run as GENERIC, that last defined each register in
    // this block, or NO_NODE; a numeric use of the register asks for it to be a typed load.
    uint* load_def;
    // The STORE_CONST node whose constant each register's window slot still holds, or NO_NODE.
    uint* const_def;
    // The rep a numeric use asked of the load at each pc (OptOverride.block); the next round
    // builds those as LOAD_CAP and LOAD_ELEM nodes.
    List {OptOverride} load_reps;
    bool load_changed;
    // The facts each loop header assumes at its start, by position (OptBuild.head_facts), once
    // head_set says it has been built: what its forward edges bring and its back edges were not
    // found to lose (OptBuild.meet_head). Kept across rounds, in which they only shrink. A round
    // without loop_facts assumes none, so that the rounds settle.
    uint* head_shape;
    bool* head_plain;
    char* head_elem;
    ulong* head_bindings;
    ulong* head_captures;
    bool* head_set;
    bool loop_facts;
    // The facts at the end of each block built so far, by position (nregs + 1 each).
    uint* end_shape;
    bool* end_plain;
    char* end_elem;
    ulong* end_bindings;
    ulong* end_captures;
    OptAvail* end_avail;
    char* end_avail_n;
    // The register states at the end and at the start of each block, by position.
    OptRegState* ends;
    OptRegState* entries;
    List{OptOverride} overrides;
    OptRefuse refused;
    Opcode refused_op;
    // Joins whose phi found no machine register in an earlier build (OptGraph.allocate): their
    // register's merged value stays in its window slot.
    List{OptJoin}* windowed;
    // The OptGraph.fns entry of the instruction being lowered, which insn, pc and next_pc index.
    uint cur_fn;
    // The instruction being lowered.
    uint insn;
    uint pc;
    uint next_pc;
    DecodedInsn w;
    bool wide;
    uint pos;
    // False once a SETCONST can change the constant table.
    bool consts_ok;
}

// Whether `f` can be optimized, or with `inlined` inlined: a sloppy function's mapped `arguments`
// that maps no formal and is only forwarded (CallFlags.forward_args) never exists in an inlined body.
fn bool opt_function_eligible(CompiledFunction* f, bool inlined = false) {
$if !types::USE_NANBOX:
    return false;
$else
    if (f.code == null || f.code_count == 0 || f.num_regs == 0 || f.num_regs >= compiler::BYTECODE_REGS_MAX) return false;
    if (f.flags.is_generator || f.flags.is_async || f.flags.has_direct_eval || f.flags.needs_lex_bridge) return false;
    return !f.mapped_arguments() || (inlined && f.call_flags.forward_args && !f.maps_formals());
$endif
}

// The function, control flow graph and liveness of the instruction being lowered. Until an inlined
// body is lowered these are the primary function's.
fn CompiledFunction* OptBuild.cur_f(&self) @inline => self.g.fns[self.cur_fn].f;
fn DecodedCfg* OptBuild.cur_cfg(&self) @inline => self.cur_fn == 0 || self.sites[self.cur_site].flat ? &self.cfg : &self.sites[self.cur_site].cfg;

// Whether graph register `r` is live into the instruction being lowered. In an inlined body that is
// the callee's registers by the callee's liveness, and the caller's by what is live after the call.
// In a nested body the registers of the bodies around it are those live after their own inlined
// call, and the callee and receiver registers of each call, which an exit stores for the frame it
// publishes.
fn bool OptBuild.live_in_at(&self, uint r) {
    if (self.cur_fn == 0) return self.live_in[self.insn].test(r);
    OptInlineSite* s = &self.sites[self.cur_site];
    if (s.flat) return self.live_in[self.insn].test(r);
    if (r >= s.base) {
        uint k = r - s.base;
        return k < s.cf.num_regs && s.live_in[self.insn].test(k);
    }
    while (true) {
        if (r == s.base - 2 || ((s.method || s.construct) && r == s.base - 1)) return true;
        // The call of a body in the spliced graph: the graph's liveness after it.
        if (s.parent == 0 || self.sites[(sz)s.parent - 1].flat) return self.live_out[s.insn].test(r);
        OptInlineSite* p = &self.sites[(sz)s.parent - 1];
        if (r >= p.base) {
            uint k = r - p.base;
            return k < p.cf.num_regs && p.live_out[s.insn].test(k);
        }
        s = p;
    }
}

// Whether graph register `r` is live after the instruction being lowered (not inside an inlined body).
fn bool OptBuild.live_out_at(&self, uint r) @inline => self.live_out[self.insn].test(r);

// The key a typed-load request (OptOverride.block) and a load_def entry give the instruction being
// lowered: its pc, and the inline site whose body it belongs to plus one (zero for the function's
// own). Sites, unlike OptGraph.fns entries, keep their index across rounds and failed inlines.
fn uint OptBuild.pckey(&self) @inline => self.pc | ((self.cur_fn == 0 ? 0 : self.cur_site + 1) << 24);

// The operands of `op` that are registers (bit 0 A, bit 1 B, bit 2 C), for the opcodes an inlined
// body may hold; zero for any other. The rest of the operands are not registers.
fn uint inline_reg_mask(Opcode op) {
    switch (op) {
        case LDINT: case LDCONST: case INC: case DEC: case INC_LT: case GETTHISC: case PUTTHISC: case RET: case THROW:
        case LDUNDEF: case LDNULL: case LDTRUE: case LDFALSE:
        case GETGLOBAL: case GETVAR: case LDTHIS: case GETCAP:
            return 1;
        // The objects an inlined body allocates (OptOp.ALLOC), whose B and C are not registers, and
        // INIT_SLOT, whose A is the object and C the value (B is the slot index).
        case NEWOBJ: case NEWOBJ_SHAPE: case NEWARR: case NEWARR_CONST: return 1;
        case INIT_SLOT: return 5;
        case GETPROP: case PUTPROP:
            return 7;
        case LDREG: case TONUMERIC: case UNM: case GETPROPC: case GETPROPC_CACHED: case PUTPROPC: case LNOT: case BNOT:
        case ADDI: case SUBI: case MULI: case BANDI: case BORI: case BXORI: case SHLI: case SHRI: case USHRI:
        case TYPEOF:
            return 3;
        // A nested inline site (OptBuild.add_children): the result and callee registers; C counts.
        case CALL: case CALL_UNDEF_THIS: case NEW_OBJ:
            return 3;
        case CALL_VAR: case CALL_GLOBAL:
            return 1;
        // A forwarding call (OptBuild.forward_candidate): the callee and count registers.
        case APPLY_ARGS: case CALL_S:
            return 7;
        case ADD: case ADD_FUSED: case SUB: case MUL: case DIV: case MOD: case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR:
        case EQ: case NEQ: case SEQ: case SNEQ: case LT: case LE: case GT: case GE:
            return 7;
        // The forward branches of a body with several blocks: A is the offset of the compares.
        case JMP_NLT..JMP_NEQ:
            return 6;
        case JMP_NULL: case JMP_NNULL:
            return 2;
        case JMP_NLTI..JMP_SNEQI:
            return 2;
        case IF_TRUE: case IF_FALSE:
            return 1;
        default:
            return 0;
    }
}

// Whether an inlined body may hold `op`: the opcodes with registers above, RETUNDEF and JUMP.
fn bool inline_op_ok(Opcode op) @inline => inline_reg_mask(op) != 0 || op == Opcode.RETUNDEF || op == Opcode.JUMP;

// The calls an inlined body may hold, each one a nested inline site. A forwarding call is the site
// of its APPLY_ARGS; the CALL_S after it is part of it.
fn bool inline_call_op(Opcode op) @inline {
    return op == Opcode.CALL || op == Opcode.CALL_UNDEF_THIS || op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL || op == Opcode.NEW_OBJ
        || op == Opcode.APPLY_ARGS;
}

// Whether instruction `k` of `cfg` is the APPLY_ARGS of `f.apply(x, arguments)`, fused with the
// CALL_S after it: the registers of the call are the callee, the function `apply` runs, its receiver.
fn bool forward_pair(DecodedCfg* cfg, uint k) {
    if (k + 1 >= cfg.instruction_count || cfg.nodes[k].view.wide || cfg.nodes[k + 1].view.wide) return false;
    DecodedInsn a = cfg.nodes[k].view.insn;
    DecodedInsn c = cfg.nodes[k + 1].view.insn;
    return a.op == Opcode.APPLY_ARGS && c.op == Opcode.CALL_S && a.b == a.a && c.a == a.a && c.b == a.a && c.c == a.c;
}

// The forward-branching opcodes of an inlined body.
fn bool inline_branch_op(Opcode op) @inline {
    return op == Opcode.JUMP || op == Opcode.IF_TRUE || op == Opcode.IF_FALSE
        || (op.ordinal >= Opcode.JMP_NLT.ordinal && op.ordinal <= Opcode.JMP_NNULL.ordinal)
        || (op.ordinal >= Opcode.JMP_NLTI.ordinal && op.ordinal <= Opcode.JMP_SNEQI.ordinal);
}

// The callee registers `w` (an instruction of an inlined body) reads and writes, as bit sets.
fn void inline_rw(DecodedInsn* w, uint* reads, uint* writes) {
    *reads = 0;
    *writes = 0;
    switch (w.op) {
        case LDINT: case LDCONST: case GETTHISC: case LDUNDEF: case LDNULL: case LDTRUE: case LDFALSE:
        case GETGLOBAL: case GETVAR: case LDTHIS: case GETCAP:
        case NEWOBJ: case NEWOBJ_SHAPE: case NEWARR: case NEWARR_CONST: *writes = 1u << w.a;
        case INIT_SLOT:
            *reads = (1u << w.a) | (1u << w.c);
        case GETPROP:
            *reads = (1u << w.b) | (1u << w.c);
            *writes = 1u << w.a;
        case PUTPROP:
            *reads = (1u << w.a) | (1u << w.b) | (1u << w.c);
        case LDREG: case TONUMERIC: case UNM: case GETPROPC: case GETPROPC_CACHED: case LNOT: case BNOT:
        case ADDI: case SUBI: case MULI: case BANDI: case BORI: case BXORI: case SHLI: case SHRI: case USHRI:
        case TYPEOF:
            *reads = 1u << w.b;
            *writes = 1u << w.a;
        case ADD: case ADD_FUSED: case SUB: case MUL: case DIV: case MOD: case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR:
        case EQ: case NEQ: case SEQ: case SNEQ: case LT: case LE: case GT: case GE:
            *reads = (1u << w.b) | (1u << w.c);
            *writes = 1u << w.a;
        case INC: case DEC: case INC_LT:
            *reads = 1u << w.a;
            *writes = 1u << w.a;
        case PUTPROPC:
            *reads = (1u << w.a) | (1u << w.b);
        case PUTTHISC: case RET: case IF_TRUE: case IF_FALSE: case THROW:
            *reads = 1u << w.a;
        case JMP_NLT..JMP_NEQ:
            *reads = (1u << w.b) | (1u << w.c);
        case JMP_NULL: case JMP_NNULL:
            *reads = 1u << w.b;
        case JMP_NLTI..JMP_SNEQI:
            *reads = 1u << w.b;
        case CALL: case CALL_UNDEF_THIS: case NEW_OBJ:
            *reads = (1u << w.b) | (w.op == Opcode.CALL ? 1u << (w.b + 1) : 0);
            for (uint k = 0; k < w.c; k++) *reads |= 1u << (w.b + 2 + k);
            *writes = 1u << w.a;
        case CALL_VAR: case CALL_GLOBAL:
            for (uint k = 0; k < w.b; k++) *reads |= 1u << (w.a + 2 + k);
            *writes = 1u << w.a;
        // The forwarded arguments are the frame's first registers, which the site checks it has.
        case APPLY_ARGS:
            *reads = (1u << w.a) | (1u << (w.a + 1)) | (1u << (w.a + 2)) | (1u << w.c);
            *writes = (1u << w.a) | (1u << (w.a + 1)) | (1u << (w.a + 2)) | (1u << w.c);
        case CALL_S:
            *reads = (1u << w.b) | (1u << (w.b + 1));
            *writes = 1u << w.a;
        default:
            break;
    }
}

// The instruction of an inlined callee as the graph sees it: its registers shifted by `base`.
fn void inline_rebase(DecodedInsn* w, uint base) {
    uint mask = inline_reg_mask(w.op);
    if ((mask & 1) != 0) w.a += base;
    if ((mask & 2) != 0) w.b += base;
    if ((mask & 4) != 0) w.c += base;
}

fn bool OptBuild.reject(&self, OptInlineReject why) {
    self.rej = why;
    return false;
}

fn void OptBuild.count_reject(&self, OptInlineReject why, Opcode op) {
    self.h.opt.inline_rejected[why.ordinal]++;
    if (self.h.opt.log && self.rej_caller != null) {
        io::eprintf("opt inline-reject ");
        opt_log_fn(self.rej_caller);
        io::eprintf(" +%d", self.rej_pc);
        if (self.rej_callee != null) {
            io::eprintf(" -> ");
            opt_log_fn(self.rej_callee);
        }
        io::eprintfn(why == OptInlineReject.OPCODE ? " %s %s" : " %s", why.label, op);
    }
    if (why == OptInlineReject.OPCODE) self.h.opt.inline_rejected_ops[op.ordinal]++;
}

fn bool OptBuild.refuse(&self, OptRefuse why) {
    if (self.refused == OptRefuse.NONE) self.refused = why;
    return false;
}

fn bool OptBuild.refuse_op(&self, Opcode op) {
    if (self.refused == OptRefuse.NONE) self.refused_op = op;
    return self.refuse(OptRefuse.OPCODE);
}

fn void OptBuild.free(&self) {
    compiler::bytecode_cfg_free(&self.cfg);
    mem::free(self.live_sets);
    mem::free(self.live_words);
    mem::free(self.b_first);
    mem::free(self.b_last);
    mem::free(self.rpo);
    mem::free(self.pos_of);
    mem::free(self.pred_off);
    mem::free(self.pred_list);
    mem::free(self.idom);
    mem::free(self.loop_end);
    mem::free(self.osr_target);
    mem::free(self.exit_in);
    mem::free(self.exit_words);
    mem::free(self.cur);
    mem::free(self.load_def);
    mem::free(self.const_def);
    mem::free(self.fact_shape);
    mem::free(self.fact_plain);
    mem::free(self.fact_elem);
    mem::free(self.head_shape);
    mem::free(self.head_plain);
    mem::free(self.head_elem);
    mem::free(self.head_bindings);
    mem::free(self.head_captures);
    mem::free(self.head_set);
    mem::free(self.end_shape);
    mem::free(self.end_plain);
    mem::free(self.end_elem);
    mem::free(self.end_bindings);
    mem::free(self.end_captures);
    mem::free(self.end_avail);
    mem::free(self.end_avail_n);
    mem::free(self.ends);
    mem::free(self.entries);
    self.overrides.free();
    self.load_reps.free();
    foreach (&s : self.sites) s.free_site();
    self.sites.free();
    mem::free(self.site_of);
    mem::free(self.fl_site);
    mem::free(self.fl_kind);
    mem::free(self.fl_local);
    mem::free(self.site_fn);
    mem::free(self.dead);
}

fn void OptInlineSite.free_site(&self) {
    compiler::bytecode_cfg_free(&self.cfg);
    mem::free(self.live_sets);
    mem::free(self.live_words);
    mem::free(self.defined);
    mem::free(self.child_of);
}

// --- Control flow analysis ---

fn uint OptBuild.succ_block(&self, uint b, uint k) {
    DecodedCfgNode* last = &self.cfg.nodes[self.b_last[b]];
    return self.cfg.nodes[last.successors[k]].block;
}

fn uint OptBuild.succ_count(&self, uint b) => self.cfg.nodes[self.b_last[b]].successor_count;

// The reachable predecessors of the block at position `pos`.
fn uint[] OptBuild.preds(&self, uint b) {
    return self.pred_list[self.pred_off[b]:self.pred_off[b + 1] - self.pred_off[b]];
}

fn bool OptBuild.dominates(&self, uint a, uint b) {
    uint x = b;
    while (true) {
        if (x == a) return true;
        if (x == 0) return false;
        x = self.idom[x];
    }
}

fn uint OptBuild.intersect(&self, uint a, uint b) {
    while (a != b) {
        while (a > b) a = self.idom[a];
        while (b > a) b = self.idom[b];
    }
    return a;
}

// The live-in set of each exit node of the region's graph: the registers the function reads after
// the region from that pc on, by the liveness of the whole function's graph at the block it starts.
fn bool OptBuild.region_exit_sets(&self) {
    CompiledFunction* f = self.f;
    DecodedCfg* cfg = &self.cfg;
    DecodedCfg whole;
    if (!compiler::bytecode_cfg_build(&whole, f.code, f.code_count, self.h, budget: OPT_REGION_LIVENESS_BUDGET, resolve: true, objects: true)) return false;
    defer compiler::bytecode_cfg_free(&whole);
    uint words = (f.num_regs + 32) / 32;
    uint nb = whole.block_count;
    RegSet* block_in = mem::new_array(RegSet, (usz)nb + 1);
    uint* block_words = mem::new_array(uint, ((usz)nb + 1) * words);
    defer { mem::free(block_in); mem::free(block_words); }
    for (uint b = 0; b <= nb; b++) block_in[b] = { .words = block_words + (usz)b * words, .word_count = words };
    compiler::bytecode_cfg_block_liveness(&whole, block_in, &block_in[nb], true, true);
    uint exits = cfg.instruction_count - cfg.exit_first;
    self.exit_in = mem::new_array(RegSet, (usz)exits + 1);
    self.exit_words = mem::new_array(uint, ((usz)exits + 1) * words);
    for (uint k = 0; k < exits; k++) {
        self.exit_in[k] = { .words = self.exit_words + (usz)k * words, .word_count = words };
        // Every exit's pc starts a block of the whole graph: it is a branch target, or follows the
        // region's last instruction, which branches.
        uint i = whole.pc_to_index[cfg.nodes[cfg.exit_first + k].view.pc];
        if (i == compiler::CFG_NO_INSTRUCTION || !whole.nodes[i].block_entry) return false;
        self.exit_in[k].copy_from(&block_in[whole.nodes[i].block]);
    }
    return true;
}

// Decode the control flow graph and order its blocks. Fails, naming the
// reason, for a function the tier does not handle.
fn bool OptBuild.analyze(&self) {
    CompiledFunction* f = self.f;
    OptRegion* rg = &self.g.region;
    compiler::DecodedCfgBudget budget = rg.end != 0 ? OPT_REGION_CFG_BUDGET : compiler::DEFAULT_CFG_BUDGET;
    if (!compiler::bytecode_cfg_build(&self.cfg, f.code, f.code_count, self.h, budget: budget, resolve: true, objects: true, start: rg.start, end: rg.end)) {
        // Name the first instruction the graph decoder does not take (--opt-log).
        for (uint pc = rg.start; pc < (rg.end != 0 ? rg.end : f.code_count);) {
            DecodedBytecode view = bytecode::decode_bytecode(f.code, f.code_count, pc);
            if (!view.valid) break;
            if (!compiler::bytecode_cfg_control_supported(view.insn.op) && view.insn.op != Opcode.RESOLVEVAR
                && view.insn.op != Opcode.THROW_UNRESOLVED && !compiler::bytecode_cfg_object_op(view.insn.op)) {
                self.refused_op = view.insn.op;
                break;
            }
            pc = view.next_pc;
        }
        return self.refuse(OptRefuse.CFG);
    }
    DecodedCfg* cfg = &self.cfg;
    uint count = cfg.instruction_count;
    self.caller_regs = f.num_regs;
    self.nregs = f.num_regs;
    self.consts_ok = true;
    for (uint i = 0; i < f.code_count; i++) if (f.code[i].op == Opcode.SETCONST) self.consts_ok = false;
    self.nb = cfg.block_count;
    if (self.nb > OPT_BLOCK_MAX || (usz)self.nb * self.nregs > OPT_STATE_MAX) return self.refuse(OptRefuse.BUDGET);
    uint words = (self.caller_regs + 32) / 32;
    self.live_sets = mem::new_array(RegSet, (usz)count * 2);
    self.live_words = mem::new_array(uint, ((usz)count * 2 + 1) * words);
    for (uint i = 0; i < count * 2; i++) self.live_sets[i] = { .words = self.live_words + (usz)i * words, .word_count = words };
    RegSet scratch = { .words = self.live_words + (usz)count * 2 * words, .word_count = words };
    if (rg.end != 0 && !self.region_exit_sets()) return self.refuse(OptRefuse.CFG);
    compiler::bytecode_cfg_liveness(cfg, self.live_sets, self.live_sets + count, &scratch, true, false, true, self.exit_in);
    self.live_out = self.live_sets;
    self.live_in = self.live_sets + count;
    self.find_sites();
    if (self.flat_count != 0) {
        if (!self.flatten()) return self.refuse(OptRefuse.CFG);
        count = cfg.instruction_count;
        self.nb = cfg.block_count;
    }
    if (self.nb > OPT_BLOCK_MAX || (usz)self.nb * self.nregs > OPT_STATE_MAX) return self.refuse(OptRefuse.BUDGET);

    self.osr_target = mem::new_array(bool, count);
    for (uint i = 0; i < count; i++) {
        uint t = cfg.nodes[i].branch_target;
        if (t != compiler::CFG_NO_INSTRUCTION && t <= i) self.osr_target[t] = true;
    }
    uint nb = self.nb;
    self.b_first = mem::new_array(uint, nb);
    self.b_last = mem::new_array(uint, nb);
    for (uint i = 0; i < count; i++) {
        uint b = cfg.nodes[i].block;
        if (cfg.nodes[i].block_entry) self.b_first[b] = i;
        self.b_last[b] = i;
    }
    // Reverse postorder by an explicit-stack depth-first search.
    self.rpo = mem::new_array(uint, nb);
    self.pos_of = mem::new_array(uint, nb);
    uint* stack = mem::new_array(uint, nb);
    uint* stack_k = mem::new_array(uint, nb);
    bool* seen = mem::new_array(bool, nb);
    defer { mem::free(stack); mem::free(stack_k); mem::free(seen); }
    for (uint b = 0; b < nb; b++) self.pos_of[b] = NO_NODE;
    uint sp = 0;
    uint post = 0;
    stack[0] = 0;
    stack_k[0] = 0;
    seen[0] = true;
    sp = 1;
    while (sp > 0) {
        uint b = stack[sp - 1];
        if (stack_k[sp - 1] < self.succ_count(b)) {
            uint s = self.succ_block(b, stack_k[sp - 1]++);
            if (!seen[s]) {
                seen[s] = true;
                stack[sp] = s;
                stack_k[sp] = 0;
                sp++;
            }
        } else {
            // Postorder numbers count up; reverse them afterwards.
            self.rpo[post++] = b;
            sp--;
        }
    }
    self.nrpo = post;
    for (uint i = 0; i < post / 2; i++) {
        uint t = self.rpo[i];
        self.rpo[i] = self.rpo[post - 1 - i];
        self.rpo[post - 1 - i] = t;
    }
    for (uint i = 0; i < post; i++) self.pos_of[self.rpo[i]] = i;
    // Predecessors as positions, over the reachable blocks.
    self.pred_off = mem::new_array(uint, (sz)post + 1);
    for (uint i = 0; i < post; i++) {
        uint b = self.rpo[i];
        for (uint k = 0; k < self.succ_count(b); k++) self.pred_off[self.pos_of[self.succ_block(b, k)] + 1]++;
    }
    for (uint i = 0; i < post; i++) self.pred_off[i + 1] += self.pred_off[i];
    self.pred_list = mem::new_array(uint, (sz)self.pred_off[post] + 1);
    uint* fill = mem::new_array(uint, post);
    defer mem::free(fill);
    for (uint i = 0; i < post; i++) {
        uint b = self.rpo[i];
        for (uint k = 0; k < self.succ_count(b); k++) {
            uint s = self.pos_of[self.succ_block(b, k)];
            self.pred_list[self.pred_off[s] + fill[s]++] = i;
        }
    }
    // Dominators (Cooper, Harvey, Kennedy).
    self.idom = mem::new_array(uint, post);
    for (uint i = 1; i < post; i++) self.idom[i] = NO_NODE;
    bool changed = true;
    while (changed) {
        changed = false;
        for (uint i = 1; i < post; i++) {
            uint nd = NO_NODE;
            foreach (p : self.preds(i)) {
                if (self.idom[p] == NO_NODE && p != 0) continue;
                nd = nd == NO_NODE ? p : self.intersect(p, nd);
            }
            if (nd != self.idom[i]) { self.idom[i] = nd; changed = true; }
        }
    }
    return self.find_loops();
}

// Check that every back edge enters a block that dominates its source (the
// graph is reducible), and find the extent of each loop: the last position of
// any block that reaches a back edge without passing through the header.
fn bool OptBuild.find_loops(&self) {
    self.loop_end = mem::new_array(uint, self.nrpo);
    bool* in_loop = mem::new_array(bool, self.nrpo);
    uint* work = mem::new_array(uint, self.nrpo);
    defer { mem::free(in_loop); mem::free(work); }
    for (uint u = 0; u < self.nrpo; u++) {
        uint ub = self.rpo[u];
        for (uint k = 0; k < self.succ_count(ub); k++) {
            uint h = self.pos_of[self.succ_block(ub, k)];
            if (h > u) continue;
            if (!self.dominates(h, u)) return self.refuse(OptRefuse.IRREDUCIBLE);
            // The natural loop: walk predecessors back from u to h.
            for (uint i = 0; i < self.nrpo; i++) in_loop[i] = false;
            in_loop[h] = true;
            uint sp = 0;
            uint extent = u > self.loop_end[h] ? u : self.loop_end[h];
            if (!in_loop[u]) { in_loop[u] = true; work[sp++] = u; }
            while (sp > 0) {
                uint x = work[--sp];
                if (x > extent) extent = x;
                foreach (p : self.preds(x)) {
                    if (in_loop[p]) continue;
                    in_loop[p] = true;
                    work[sp++] = p;
                }
            }
            self.loop_end[h] = extent;
        }
    }
    return true;
}

// --- Registers ---

fn OptRep OptBuild.rep_of(&self, uint node) @inline => self.g.nodes[node].rep;

fn uint OptBuild.add(&self, OptOp op, OptRep rep, uint a = NO_NODE, uint b = NO_NODE, long imm = 0) {
    if (!keeps_fresh(op)) self.fresh_n = 0;
    OptNode n = { .op = op, .rep = rep, .a = a, .b = b, .c = NO_NODE, .imm = imm, .pc = self.pc, .fidx = self.cur_fn, .reg = -1, .home = NO_NODE, .shape = heap::SHAPE_NONE };
    self.g.nodes.push(n);
    return (uint)self.g.nodes.len() - 1;
}

// Whether a node of kind `op` leaves an object being built as the code knows it: it runs no code,
// does not collect, changes no object's shape (an ADD_FIELD is accounted for where it is built)
// and does not end the block.
fn bool keeps_fresh(OptOp op) {
    switch (op) {
        case CONST_I32: case CONST_F64: case CONST_OBJ: case CHECK_I32: case CHECK_NUM: case LOAD_CAP:
        case LOAD_FIELD: case LOAD_LENGTH: case STORE_FIELD: case STORE_VALUE: case COPY:
        case ADD_I32: case SUB_I32: case MUL_I32: case AND_I32: case OR_I32: case XOR_I32: case NOT_I32:
        case SHL_I32: case SAR_I32: case SHR_I32: case MOD_I32: case I32_TO_F64: case F64_TO_I32:
        case ADD_F64: case SUB_F64: case MUL_F64: case DIV_F64: case NEG_F64: case MATH:
        case CHECK_CALLEE: case LOAD_VAR: case LOAD_GLOBAL: case GUARD_BINDING: case GUARD_CAPTURE:
        case COPY_WINDOW: case STORE_CONST: case TYPEOF: case COMPARE: case LNOT: case NEW_OBJECT:
        case CHECK_BUILTIN: case MOVE_WINDOW: case ADD_FIELD:
            return true;
        default:
            return false;
    }
}

// Node `node` is a NEW_OBJECT for a constructor `cf`: its object starts out empty, with room for
// what the constructor adds.
fn void OptBuild.note_fresh(&self, uint node, CompiledFunction* cf) {
    uint want = opt_constructor_want(cf);
    if (want > hobject::SHAPED_INLINE_MAX_PROPS || self.fresh_n == OPT_FRESH_MAX) return;
    self.fresh[self.fresh_n++] = { .node = node, .shape = 0, .count = 0, .capacity = vm::constructor_inline_capacity(want) };
}

// The ADD_FIELD node `n` adds `key` to the object of VALUE node `recv`. When that is an object
// being built, the add is the shared transition from the shape it has, if there is one and the
// object has room: the node records the shape it leaves (cc 1), and so does the object.
fn void OptBuild.add_known(&self, uint n, uint recv, void* key) {
    for (uint k = 0; k < self.fresh_n; k++) {
        OptFresh* fr = &self.fresh[k];
        if (fr.node != recv) continue;
        uint next = fr.count < fr.capacity ? self.h.lookup_transition(fr.shape, key, (char)hobject::PROP_FLAGS_WEC) : heap::SHAPE_NONE;
        hobject::Shape* sh = next != heap::SHAPE_NONE ? self.h.get_shape(next) : null;
        if (sh == null || sh.parent == hobject::PRIVATE_SHAPE_PARENT || sh.offset + sh.own_count != fr.count + 1) {
            self.fresh[k] = self.fresh[--self.fresh_n];
            return;
        }
        self.g.nodes[n].cc = 1;
        self.g.nodes[n].shape = next;
        fr.shape = next;
        fr.count++;
        return;
    }
}

// Record the dirty registers live into the current instruction on node `node`.
fn void OptBuild.snapshot(&self, uint node) {
    uint first = (uint)self.g.dirty.len();
    for (uint r = 0; r < self.nregs; r++) {
        OptRegState s = self.cur[r];
        if (s.node != NO_NODE && s.dirty && self.live_in_at(r)) {
            self.g.dirty.push({ .reg = r, .node = s.node });
        }
    }
    OptNode* n = &self.g.nodes[node];
    n.dirty_first = first;
    n.dirty_count = (uint)self.g.dirty.len() - first;
    if (self.cur_fn != 0) {
        OptInlineSite* s = &self.sites[self.cur_site];
        if (s.flat) {
            uint local = self.fl_local[self.insn];
            for (uint k = 0; k < s.cf.num_regs; k++) if (self.live_in[self.insn].test(s.base + k) && (s.defined[local] & (1u << k)) != 0) n.live_mask |= 1u << k;
        } else {
            for (uint k = 0; k < s.cf.num_regs; k++) if (s.live_in[self.insn].test(k) && (s.defined[self.insn] & (1u << k)) != 0) n.live_mask |= 1u << k;
        }
    }
}

fn uint OptBuild.guarded(&self, OptOp op, OptRep rep, uint reg) {
    uint n = self.add(op, rep, NO_NODE, NO_NODE, (long)reg);
    self.g.nodes[n].home = reg;
    self.snapshot(n);
    return n;
}

fn void OptBuild.set(&self, uint reg, uint node, bool dirty = true) {
    if (reg >= self.nregs) return;
    if (node != NO_NODE && !self.g.nodes[node].is_const() && self.g.nodes[node].op != OptOp.PHI) self.g.nodes[node].home = reg;
    self.cur[reg] = { .node = node, .dirty = dirty };
    self.load_def[reg] = NO_NODE;
    self.const_def[reg] = NO_NODE;
    self.fact_shape[reg] = heap::SHAPE_NONE;
    self.fact_elem[reg] = 0;
    self.drop_reg(reg, node);
}

// Facts about objects are only held across nodes that neither run code nor allocate: LOAD_FIELD,
// STORE_FIELD (an overwrite, so never a shape change), LOAD_ELEM, STORE_ELEM, numeric ops and
// branches. Nothing then can collect an object, recycle a shape id or rebind a register, so the
// shape cell a node compared is still the receiver's. Every GENERIC, write to the register and
// join the ways in disagree on (begin_block) drops its facts.
fn void OptBuild.forget_facts(&self) {
    for (uint r = 0; r <= self.nregs; r++) self.fact_shape[r] = heap::SHAPE_NONE;
    mem::clear(self.fact_elem, (usz)self.nregs + 1);
    self.fact_bindings = 0;
    self.avail_n = 0;
}

// The register a field node reads its receiver from: nregs for `this`.
fn uint OptBuild.field_receiver(&self) {
    switch (self.w.op) {
        case GETTHISC: case PUTTHISC: return self.cur_fn == 0 ? self.nregs : self.sites[self.cur_site].base - 1;
        case GETPROPC: case GETPROPC_CACHED: return self.w.b;
        default: return self.w.a;
    }
}

// Whether the receiver of the field node being lowered is already known to be an object of
// `shape` that passes the node's guards.
fn bool OptBuild.guards_known(&self, uint reg, uint shape) {
    if (reg > self.nregs || self.fact_shape[reg] != shape) return false;
    return self.fact_plain[reg] || (self.w.op != Opcode.PUTPROPC && self.w.op != Opcode.PUTTHISC);
}

// Register `dst` was given the value of register `src`: what is known of the object goes with it.
fn void OptBuild.same_facts(&self, uint dst, uint src) {
    if (dst >= self.nregs) return;
    self.fact_shape[dst] = self.fact_shape[src];
    self.fact_plain[dst] = self.fact_plain[src];
    self.fact_elem[dst] = self.fact_elem[src];
}

fn void OptBuild.learn(&self, uint reg, uint shape) {
    if (reg > self.nregs) return;
    self.fact_shape[reg] = shape;
    self.fact_plain[reg] = self.w.op == Opcode.PUTPROPC || self.w.op == Opcode.PUTTHISC;
}

fn uint OptBuild.const_i32(&self, long v) => self.add(OptOp.CONST_I32, OptRep.INT32, NO_NODE, NO_NODE, v);

fn uint OptBuild.const_f64(&self, double v) {
    long bits;
    if (v != v) {
        bits = 0x7FF8000000000000;
    } else {
        mem::copy(&bits, &v, 8);
    }
    return self.add(OptOp.CONST_F64, OptRep.FLOAT64, NO_NODE, NO_NODE, bits);
}

// The register's value as a node of rep `want`, checking it when it is in the
// window; NO_NODE when the register is out of range.
fn uint OptBuild.operand(&self, uint reg, OptRep want) {
    if (reg >= self.nregs) return NO_NODE;
    OptRegState s = self.cur[reg];
    if (s.node != NO_NODE && self.rep_of(s.node) == OptRep.VALUE) {
        // A field read of this body kept beyond the caller's frame as a VALUE node only for want
        // of a use (OptBuild.get_field): the next round reads it as a number.
        OptNode* ld = &self.g.nodes[s.node];
        bool load = ld.op == OptOp.LOAD_FIELD || ld.op == OptOp.LOAD_ELEM || ld.op == OptOp.LOAD_GLOBAL;
        if (self.cur_fn != 0 && reg >= self.caller_regs && load && ld.fidx == self.cur_fn) {
            self.ask_load(ld.pc | ((self.cur_site + 1) << 24), reg, want);
        }
        // A number was asked of a register that holds an object: read it from the window as any other
        // value there (the guard exits when it is not a number).
        self.publish_value(reg);
        self.kill(reg);
        s = self.cur[reg];
    }
    if (s.node == NO_NODE && self.load_def[reg] != NO_NODE) self.ask_load(self.load_def[reg], reg, want);
    if (s.node == NO_NODE) {
        uint n = self.guarded(want == OptRep.INT32 ? OptOp.CHECK_I32 : OptOp.CHECK_NUM, want, reg);
        self.set(reg, n, false);
        return n;
    }
    return self.convert(s.node, want);
}

// Node `node` as `want`: INT32 widens to FLOAT64; FLOAT64 narrows to INT32 by
// ToInt32 (the caller only asks for that for the bitwise operators).
fn uint OptBuild.convert(&self, uint node, OptRep want) {
    OptRep have = self.rep_of(node);
    if (have == want) return node;
    OptNode* n = &self.g.nodes[node];
    if (have == OptRep.INT32) {
        if (n.op == OptOp.CONST_I32) return self.const_f64((double)n.imm);
        return self.add(OptOp.I32_TO_F64, OptRep.FLOAT64, node);
    }
    if (n.op == OptOp.CONST_F64) {
        double d;
        long bits = n.imm;
        mem::copy(&d, &bits, 8);
        if (d >= -2147483648.0 && d <= 2147483647.0 && d == d) return self.const_i32((long)d);
    }
    uint c = self.add(OptOp.F64_TO_I32, OptRep.INT32, node);
    self.snapshot(c);
    return c;
}

fn bool OptBuild.state_float(&self, uint reg) {
    return reg < self.nregs && self.cur[reg].node != NO_NODE && self.rep_of(self.cur[reg].node) == OptRep.FLOAT64;
}

// The feedback the baseline recorded for the instruction being lowered.
fn char OptBuild.feedback(&self) {
    CompiledFunction* f = self.cur_f();
    if (f.ic_entries == null) return 0;
    return ((hobject::ICEntry*)f.ic_entries)[self.next_pc - 1].feedback;
}

// The rep an arithmetic or comparison instruction runs in: FLOAT64 when an
// operand is one, a double was seen, or the integer result has left the
// integer range; NONE when a non-number was seen.
fn OptRep OptBuild.arith_rep(&self, uint rb, uint rc) {
    char fb = self.feedback();
    if ((fb & (hobject::FB_STR | hobject::FB_OTHER)) != 0) return OptRep.NONE;
    if ((fb & (hobject::FB_DBL | hobject::FB_OVF)) != 0) return OptRep.FLOAT64;
    if (self.state_float(rb) || self.state_float(rc)) return OptRep.FLOAT64;
    return OptRep.INT32;
}

fn uint OptBuild.imm_operand(&self, long v, OptRep rep) {
    return rep == OptRep.FLOAT64 ? self.const_f64((double)v) : self.const_i32(v);
}

// `A = B op C` (or op imm) in the rep the feedback and operands select.
fn bool OptBuild.arith(&self, OptOp int_op, OptOp float_op, uint rb, uint rc, bool imm, long imm_value) {
    OptRep rep = self.arith_rep(rb, imm ? NO_NODE : rc);
    // `(a + b) | 0`: an int32 sum only ToInt32 reads is the wrapped 32-bit sum, overflow or not.
    bool wrap = self.wraps(rb, imm ? NO_NODE : rc);
    if (wrap) rep = OptRep.INT32;
    if (rep == OptRep.NONE) return self.generic();
    uint x = self.operand(rb, rep);
    uint y = imm ? self.imm_operand(imm_value, rep) : self.operand(rc, rep);
    if (x == NO_NODE || y == NO_NODE) return self.generic();
    uint n = self.add(rep == OptRep.INT32 ? int_op : float_op, rep, x, y);
    if (wrap) {
        self.g.nodes[n].cc = 1;
    } else if (rep == OptRep.INT32) {
        self.snapshot(n);
    }
    self.set(self.w.a, n);
    return true;
}

// Whether the ADD, SUB, ADDI or SUBI being lowered may wrap: its operands are int32 (an operand in
// the window is guarded as one before it) and its result reaches only ToInt32 (truncated_use).
fn bool OptBuild.wraps(&self, uint rb, uint rc) {
    Opcode op = self.w.op;
    if (op != Opcode.ADD && op != Opcode.SUB && op != Opcode.ADDI && op != Opcode.SUBI) return false;
    if (self.cur_fn != 0 || self.wide || (self.feedback() & (hobject::FB_DBL | hobject::FB_STR | hobject::FB_OTHER)) != 0) return false;
    if (self.state_float(rb) || (rc != NO_NODE && self.state_float(rc))) return false;
    if (self.holds_value(rb) || (rc != NO_NODE && self.holds_value(rc))) return false;
    return self.truncated_use(self.insn, self.w.a, 3);
}

// Whether the value instruction `insn` of the function's own body writes to `reg` is read only by
// ToInt32, so that the sum it holds may be the wrapped one: the next instruction reads it as a
// bitwise operand, or (at most `depth` deep) as an operand of an add or subtract of int32 values
// whose result is read only so in turn, and the register is dead after it. The exact sums of a few
// int32 values are exact doubles, so ToInt32 of the end result is the same either way; an exit
// between them resumes with the wrapped value, which the same argument covers, since no
// instruction of the chain can exit on it (its other operands are int32 nodes already).
fn bool OptBuild.truncated_use(&self, uint insn, uint reg, uint depth) {
    DecodedCfg* cfg = &self.cfg;
    if (reg >= self.nregs || insn + 1 >= cfg.instruction_count) return false;
    DecodedCfgNode* next = &cfg.nodes[insn + 1];
    if (next.view.wide) return false;
    DecodedInsn w = next.view.insn;
    bool dead_after = w.a == reg || !self.live_out[insn + 1].test(reg);
    switch (w.op) {
        case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR:
            return (w.b == reg || w.c == reg) && (dead_after || w.a == reg);
        case BANDI: case BORI: case BXORI: case SHLI: case SHRI: case USHRI:
            return w.b == reg && dead_after;
        case ADD: case SUB: case ADDI: case SUBI:
            if (depth == 0 || !dead_after || w.a >= self.nregs) return false;
            bool imm = w.op == Opcode.ADDI || w.op == Opcode.SUBI;
            if (w.b != reg && (imm || w.c != reg)) return false;
            if (self.f.ic_entries != null && (((hobject::ICEntry*)self.f.ic_entries)[next.view.payload_pc].feedback & (hobject::FB_DBL | hobject::FB_STR | hobject::FB_OTHER)) != 0) return false;
            if (!imm) {
                uint other = w.b == reg ? w.c : w.b;
                if (other != reg && (other >= self.nregs || other == self.w.a || self.cur[other].node == NO_NODE || self.rep_of(self.cur[other].node) != OptRep.INT32)) return false;
            }
            return self.truncated_use(insn + 1, w.a, depth - 1);
        default:
            return false;
    }
}

// The bitwise operators: INT32 operands, a double taken through ToInt32 when
// one was seen.
fn bool OptBuild.bitop(&self, OptOp op, uint rb, uint rc, bool imm, long imm_value) {
    char fb = self.feedback();
    if ((fb & (hobject::FB_STR | hobject::FB_OTHER)) != 0) return self.generic();
    bool numbers = (fb & (hobject::FB_DBL | hobject::FB_OVF)) != 0 || self.state_float(rb) || (!imm && self.state_float(rc));
    uint x = self.bit_operand(rb, numbers);
    uint y = imm ? self.const_i32(imm_value) : self.bit_operand(rc, numbers);
    if (x == NO_NODE || y == NO_NODE) return self.generic();
    uint n = self.add(op, OptRep.INT32, x, y);
    if (op == OptOp.SHR_I32) {
        if (self.cur_fn == 0 && !self.wide && self.truncated_use(self.insn, self.w.a, 3)) {
            // Only ToInt32 reads it: the uint32 result as the int32 with its bits.
            self.g.nodes[n].cc = 2;
        } else if ((fb & hobject::FB_OVF) != 0) {
            // A result of 2^31 or above has exited: the uint32 result as a double.
            self.g.nodes[n].cc = 1;
            // Spilled, it is stored to the slot its conversion then overwrites.
            self.g.nodes[n].home = self.w.a;
            self.set(self.w.a, self.add(OptOp.I32_TO_F64, OptRep.FLOAT64, n));
            return true;
        } else {
            self.snapshot(n);
        }
    }
    self.set(self.w.a, n);
    return true;
}

fn uint OptBuild.bit_operand(&self, uint reg, bool numbers) {
    if (reg >= self.nregs) return NO_NODE;
    if (self.cur[reg].node == NO_NODE && numbers) {
        uint c = self.operand(reg, OptRep.FLOAT64);
        return c == NO_NODE ? c : self.convert(c, OptRep.INT32);
    }
    return self.operand(reg, OptRep.INT32);
}

// A numeric use of `reg` found it still in the window, written by the GETCAP or GETPROP at `pc`:
// have the next round build that as a typed load of `want`.
fn void OptBuild.ask_load(&self, uint pc, uint reg, OptRep want) {
    foreach (&c : self.load_reps) {
        if (c.block != pc) continue;
        if (c.rep != want && (c.rep != OptRep.VALUE || c.soft)) {
            c.rep = want;
            c.soft = false;
            self.load_changed = true;
        }
        return;
    }
    self.load_reps.push({ .block = pc, .reg = reg, .rep = want });
    self.load_changed = true;
}

// The typed load a numeric use asked of the instruction at this pc, or NO_NODE.
fn uint OptBuild.typed_load(&self, OptOp op, uint a) {
    OptRep rep;
    if (!self.asked_rep(&rep)) return NO_NODE;
    uint n = self.add(op, rep, a, NO_NODE, (long)self.pc);
    self.snapshot(n);
    self.set(self.w.a, n);
    return n;
}

// Whether a use asked the load being lowered for a node, and of which rep.
fn bool OptBuild.asked_rep(&self, OptRep* rep) {
    foreach (c : self.load_reps) {
        if (c.block != self.pckey()) continue;
        // A load that has exited with a value an int32 node cannot hold (opt_note_operands) reads
        // a double; its int32 uses convert it, or (as an index) leave the access to the baseline.
        *rep = c.rep;
        if (c.rep == OptRep.INT32 && (self.feedback() & hobject::FB_DBL) != 0) *rep = OptRep.FLOAT64;
        return true;
    }
    return false;
}

// The node holding the value of field `key` of the receiver, the VALUE node `recv` (the root of
// its copies) or window register `reg` when recv is NO_NODE, or NO_NODE.
fn uint OptBuild.held_field(&self, void* key, uint recv, uint reg) {
    for (uint i = 0; i < self.avail_n; i++) {
        OptAvail e = self.avail[i];
        if (e.key == key && e.recv == recv && (recv != NO_NODE || e.reg == reg)) return e.node;
    }
    return NO_NODE;
}

// Field `key` of the receiver (as held_field names it) holds the value of `node`.
fn void OptBuild.note_field(&self, void* key, uint recv, uint reg, uint node) {
    OptAvail e = { .key = key, .recv = recv, .reg = recv == NO_NODE ? reg : NO_NODE, .node = node };
    for (uint i = 0; i < self.avail_n; i++) {
        OptAvail* x = &self.avail[i];
        if (x.key == e.key && x.recv == e.recv && x.reg == e.reg) {
            x.node = node;
            return;
        }
    }
    if (self.avail_n == OPT_AVAIL_MAX) {
        for (uint i = 1; i < OPT_AVAIL_MAX; i++) self.avail[i - 1] = self.avail[i];
        self.avail_n--;
    }
    self.avail[self.avail_n++] = e;
}

// A write of field `key`, to an object any receiver may be.
fn void OptBuild.drop_key(&self, void* key) {
    uint kept = 0;
    for (uint i = 0; i < self.avail_n; i++) if (self.avail[i].key != key) self.avail[kept++] = self.avail[i];
    self.avail_n = kept;
}

// Register `reg` now holds `node`: it no longer holds the receiver of the fields read through it,
// and its slot is no longer where the value of another node that lost its machine register lives.
fn void OptBuild.drop_reg(&self, uint reg, uint node) {
    uint kept = 0;
    for (uint i = 0; i < self.avail_n; i++) {
        OptAvail e = self.avail[i];
        if (e.reg == reg || (e.node != node && self.g.nodes[e.node].home == reg)) continue;
        self.avail[kept++] = e;
    }
    self.avail_n = kept;
}

// GETCAP: a typed load (a number, or a VALUE) when a use asked for one; else the value read into
// the window. In an inlined body a value of any kind
// in a slot beyond the caller's frame would be out of the collector's sight.
fn bool OptBuild.get_cap(&self) {
    // The read takes the callee's closure from its window slot, or from the VALUE node a nested
    // call's guard checked.
    uint closure = self.cur_fn == 0 ? NO_NODE : self.cur[self.sites[self.cur_site].base - 2].node;
    if (closure != NO_NODE && self.rep_of(closure) != OptRep.VALUE) return self.generic();
    if (self.w.a < self.nregs && self.fold_capture()) return true;
    uint t = self.typed_load(OptOp.LOAD_CAP, NO_NODE);
    if (t != NO_NODE) {
        self.g.nodes[t].b = closure;
        return true;
    }
    uint ra = self.w.a;
    if (ra >= self.nregs) return self.cur_fn == 0 ? self.generic() : false;
    // A site that has left through the slow path repeatedly (an uninitialized binding) runs the
    // baseline's read.
    if (self.cur_fn == 0 && opt_site_banned(self.f, self.f, self.next_pc - 1)) {
        if (!self.generic()) return false;
        self.load_def[ra] = self.pckey();
        return true;
    }
    uint n = self.add(OptOp.LOAD_CAP, OptRep.NONE, NO_NODE, closure, (long)self.pc);
    self.snapshot(n);
    self.kill(ra);
    self.load_def[ra] = self.pckey();
    if (ra >= self.caller_regs) self.inline_unsafe = true;
    return true;
}

// GETGLOBAL: a typed load when a numeric use asked for one, else the value read into the window;
// the cache not holding leaves for the baseline code. In an inlined body a value of any kind in a
// slot beyond the caller's frame would be out of the collector's sight.
fn bool OptBuild.get_global(&self) {
    return self.get_variable(false);
}

// GETVAR in an inlined body, as GETGLOBAL, through its scope cache. The cache is keyed by the scope
// chain the function runs with, which is the callee closure's, not the running frame's: the read
// takes the closure from its window slot, or from the VALUE node a nested call's guard checked
// (the node's cc is 1, b the closure node).
fn bool OptBuild.get_scoped(&self) {
    return self.get_variable(true);
}

// The VALUE node holding the closure of the body being lowered (NO_NODE when it is in its window
// slot, or the function's own body); false when the slot holds a node of another kind.
fn bool OptBuild.body_closure(&self, uint* node) {
    *node = NO_NODE;
    if (self.cur_fn == 0) return true;
    uint c = self.cur[self.sites[self.cur_site].base - 2].node;
    if (c != NO_NODE && self.rep_of(c) != OptRep.VALUE) return false;
    *node = c;
    return true;
}

fn bool OptBuild.get_variable(&self, bool scoped) {
    uint ra = self.w.a;
    if (ra >= self.nregs) return false;
    if (!scoped && self.fold_global()) return true;
    uint closure = NO_NODE;
    if (scoped && !self.body_closure(&closure)) return self.generic();
    uint t = self.typed_load(OptOp.LOAD_GLOBAL, NO_NODE);
    if (t != NO_NODE) {
        self.g.nodes[t].cc = scoped ? 1 : 0;
        self.g.nodes[t].b = closure;
        return true;
    }
    uint n = self.add(OptOp.LOAD_VAR, OptRep.NONE, NO_NODE, closure, (long)self.pc);
    self.g.nodes[n].cc = scoped ? 1 : 0;
    self.snapshot(n);
    self.kill(ra);
    self.load_def[ra] = self.pckey();
    if (ra >= self.caller_regs) self.soft_value(ra);
    return true;
}

// The fact bits of fact_bindings: OptGraph.bindings entries from bit 0, the layouts of the
// OptGraph.holders from OPT_FACT_HOLDER, and the folded-object epoch.
const uint OPT_BINDINGS_MAX = 56;
const uint OPT_HOLDERS_MAX = 4;
const uint OPT_FACT_HOLDER = 56;
const ulong OPT_FACT_EPOCH = 1UL << 62;

// GETGLOBAL of a binding the code can fold: a `var` or function declaration of a script, which is a
// non-configurable data property of the global object.
fn bool OptBuild.fold_global(&self) {
    CompiledFunction* f = self.cur_f();
    uint pc = self.next_pc - 1;
    if (f.var_ic_entries == null || opt_site_banned(self.f, f, pc, true)) return false;
    hobject::VarICEntry* vic = &((hobject::VarICEntry*)f.var_ic_entries)[pc];
    // The cache names the binding while its epoch is the heap's; the global environment is the
    // one with no parent, and its bindings are the global object.
    if (vic.slot_ptr == null || vic.recycle_epoch != self.h.shape_recycle_epoch || vic.env == null) return false;
    if (((env::EnvRecord*)vic.env).parent != null || vic.prop_flags.is_accessor || vic.prop_flags.configurable) return false;
    uint k = self.binding_entry((HObject*)vic.bindings, vic.slot_ptr);
    if (k == NO_NODE) return false;
    self.fold_binding(k);
    return true;
}

// GETCAP of the function being optimized, of a binding the code can fold through the capture
// record of the closure that was running it (OptBuild.refs): a declared binding of the scope or cell
// that holds it, or a value snapshot. A GUARD_CAPTURE proves the record once in a frame.
fn bool OptBuild.fold_capture(&self) {
    uint index = self.w.get_bc();
    if (self.cur_fn != 0 || index >= self.f.capture_count || index >= 64 || opt_site_banned(self.f, self.f, self.next_pc - 1, true)) return false;
    CaptureRef* refs = self.frame_refs();
    if (refs == null) return false;
    CaptureRef* ref = &refs[index];
    HObject* holder = null;
    hobject::PropValue* slot = null;
    if (!ref.is_value) {
        holder = ref.owner;
        if (holder == null || ref.guard_shadow || ref.prop_idx >= holder.prop_count) return false;
        hobject::PropFlags flags = holder.get_prop_flags(ref.prop_idx, self.h);
        if (flags.is_accessor || (!ref.is_cell && flags.configurable)) return false;
        slot = &holder.prop_values()[ref.prop_idx];
    }
    uint k = self.binding_entry(holder, ref.is_value ? (hobject::PropValue*)&ref.value : slot);
    if (k == NO_NODE) return false;
    if ((self.fact_captures & (1UL << index)) == 0) {
        uint c = (uint)self.g.captures.len();
        foreach (j, &cap : self.g.captures) if (cap.index == index) c = (uint)j;
        if (c == self.g.captures.len()) {
            OptCapture cap = { .index = index };
            mem::copy(&cap.words, ref, CaptureRef::size);
            self.g.captures.push(cap);
        }
        uint g = self.add(OptOp.GUARD_CAPTURE, OptRep.NONE, NO_NODE, NO_NODE, (long)c);
        self.snapshot(g);
        self.fact_captures |= 1UL << index;
    }
    self.fold_binding(k);
    return true;
}

// The capture records of the closure running the frame that asked for the compile, when it runs
// the function being optimized. Its code reads them, as the GETCAP being lowered does, so even a
// frame generated code pushed has its function written (vm::ACT_FLAG_LAZY).
fn CaptureRef* OptBuild.frame_refs(&self) {
    OptGraph* g = self.g;
    if (!g.refs_read) {
        g.refs_read = true;
        uint count;
        if (g.frame != null && g.frame.func == (void*)self.f) g.refs = vm::capture_refs_of(g.frame, &count);
        if (g.refs != null && count != self.f.capture_count) g.refs = null;
    }
    return g.refs;
}

// Whether the binding value `v` is one the code folds: a number, or a typed array whose elements the
// code then addresses directly. Other objects, often rebound, gain nothing yet.
fn bool OptBuild.fold_value(&self, TVal v) {
    if (v.is_numeric()) return true;
    OptView view;
    return v.is_object() && opt_const_view(v.get_raw_bits(), false, &view);
}

// The OptGraph.bindings entry for the binding at `slot` of `holder` (none for a value snapshot),
// added with its holder's when the value is one to fold; NO_NODE when it is not, or when the
// binding's guard failed somewhere (opt_unfolded).
fn uint OptBuild.binding_entry(&self, HObject* holder, hobject::PropValue* slot) {
    Heap* h = self.h;
    TVal v = slot.get();
    if (!self.fold_value(v) || (holder != null && opt_unfolded(&h.opt, slot))) return NO_NODE;
    uint ho = OPT_NO_HOLDER;
    if (holder != null) {
        hobject::Shape* shape = h.get_shape(holder.shape_id);
        if (shape == null) return NO_NODE;
        ho = (uint)self.g.holders.len();
        foreach (j, &x : self.g.holders) if (x.obj == holder) ho = (uint)j;
        if (ho == self.g.holders.len()) {
            if (ho >= OPT_HOLDERS_MAX) return NO_NODE;
            self.g.holders.push({ .obj = holder, .shape = holder.shape_id, .gen = shape.generation });
        }
    }
    ulong bits = v.get_raw_bits();
    uint k = (uint)self.g.bindings.len();
    foreach (j, &b : self.g.bindings) if (b.holder == ho && b.value == bits && (holder == null || b.slot == slot)) k = (uint)j;
    if (k == self.g.bindings.len()) {
        if (k >= OPT_BINDINGS_MAX) return NO_NODE;
        self.g.bindings.push({ .holder = ho, .slot = holder != null ? slot : null, .value = bits });
    }
    return k;
}

// The value of binding `k` as a constant node, after a GUARD_BINDING unless one has proven it since
// the last node that runs code.
fn void OptBuild.fold_binding(&self, uint k) {
    OptBinding* b = &self.g.bindings[k];
    uint ho = b.holder;
    TVal v = { .bits = b.value };
    bool object = v.is_object();
    bool holder = ho != OPT_NO_HOLDER;
    ulong need = (1UL << k) | (holder ? 1UL << (OPT_FACT_HOLDER + ho) : 0) | (object ? OPT_FACT_EPOCH : 0);
    if ((self.fact_bindings & need) != need) {
        char cc = 0;
        if (holder && (self.fact_bindings & (1UL << (OPT_FACT_HOLDER + ho))) == 0) cc |= OPT_GUARD_LAYOUT;
        if (object && (self.fact_bindings & OPT_FACT_EPOCH) == 0) cc |= OPT_GUARD_EPOCH;
        uint g = self.add(OptOp.GUARD_BINDING, OptRep.NONE, NO_NODE, NO_NODE, (long)k);
        self.g.nodes[g].cc = cc;
        self.snapshot(g);
        self.fact_bindings |= need;
    }
    uint n;
    if (v.is_fastint() && v.get_fastint() >= int::min && v.get_fastint() <= int::max) {
        n = self.const_i32(v.get_fastint());
    } else if (v.is_numeric()) {
        n = self.const_f64(v.get_number_or_fastint());
    } else {
        // Its death would let its address name another object: folded, it moves the epoch first.
        ((HObject*)v.get_heapptr()).gc.folded = true;
        n = self.add(OptOp.CONST_OBJ, OptRep.VALUE, NO_NODE, NO_NODE, (long)b.value);
    }
    self.set(self.w.a, n);
}

// A typed array whose elements an access can address directly when it is a constant: a
// fixed-length view of a fixed-length buffer whose store is in place. The GUARD_BINDING that proves
// the value also proves the store in place (a detach clears it, and nothing else moves it). An
// element store also needs a buffer that is not immutable and a kind that does not clamp.
struct OptView {
    // The index into TYPED_KINDS, its shift and load or store move.
    uint kind;
    HObject* buffer;
    char* base;
    char* data;
    uint length;
}

fn bool opt_const_view(ulong bits, bool store, OptView* out) {
$if features::BUFFERS:
    TVal v = { .bits = bits };
    if (!v.is_object()) return false;
    HObject* o = (HObject*)v.get_heapptr();
    if (o.flags.exotic_proxyobj || o.flags.has_indexed_named_prop) return false;
    foreach (k, kind : TYPED_KINDS) {
        if (o.flags.obj_class != kind.cls) continue;
        if (store && kind.cls == hobject::ObjClass.UINT8CLAMPEDARRAY) return false;
        hobject::HObjectBufferView* view = &(*o.extra_ptr()).view;
        if (view.buffer == null || view.length_tracking) return false;
        hobject::HObjectArrayBuffer* ab = &(*view.buffer.extra_ptr()).ab;
        if (ab.data == null || ab.resizable || (store && ab.immutable)) return false;
        *out = { .kind = (uint)k, .buffer = view.buffer, .base = ab.data, .data = ab.data + view.byte_offset, .length = view.byte_length >> kind.shift };
        return true;
    }
    return false;
$else
    return false;
$endif
}

// The CONST_OBJ node register `r` holds when its value is a typed array opt_const_view accepts,
// with the view; else NO_NODE.
fn uint OptBuild.const_view(&self, uint r, bool store, OptView* view) {
    if (r >= self.nregs || self.cur[r].node == NO_NODE) return NO_NODE;
    OptNode* n = &self.g.nodes[self.cur[r].node];
    if (n.op != OptOp.CONST_OBJ || !opt_const_view((ulong)n.imm, store, view)) return NO_NODE;
    return self.cur[r].node;
}

// LDTHIS in an inlined method call: the receiver the call checked to be an object, copied to the
// register.
fn bool OptBuild.load_this(&self) {
    uint ra = self.w.a;
    if (ra >= self.nregs) return false;
    uint recv = self.sites[self.cur_site].base - 1;
    // The receiver of a nested call held in a VALUE node.
    if (self.holds_value(recv)) {
        self.set(ra, self.add(OptOp.COPY, OptRep.VALUE, self.cur[recv].node));
    } else if (!self.window_copy(ra, 1)) {
        return false;
    }
    self.same_facts(ra, recv);
    return true;
}

// A window value copied to register `ra` of an inlined body, from the receiver slot (cc 1), register
// B of the instruction (cc 2) or register A (cc 0, a return). A slot beyond the caller's frame takes
// it in a register as a VALUE node instead, which exits for any other value.
fn bool OptBuild.window_copy(&self, uint ra, char cc, uint* node = null) {
    if (ra >= self.nregs) return false;
    bool beyond = ra >= self.caller_regs;
    uint n = self.add(OptOp.COPY_WINDOW, beyond ? OptRep.VALUE : OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
    self.g.nodes[n].home = ra;
    self.g.nodes[n].cc = cc;
    self.snapshot(n);
    if (node != null) {
        *node = beyond ? n : NO_NODE;
    } else if (beyond) {
        self.set(ra, n);
    } else {
        self.kill(ra);
    }
    return true;
}

// Whether the instruction being lowered has been cached for a string key.
fn bool OptBuild.string_keyed(&self) {
    CompiledFunction* f = self.cur_f();
    if (f.ic_entries == null) return true;
    return ((hobject::ICEntry*)f.ic_entries)[self.next_pc - 1].key.borrow() != null;
}

// Whether register `r` can be an element index: an INT32 node, or the window while the
// instruction has seen no string key.
fn bool OptBuild.index_ok(&self, uint r) {
    if (r >= self.nregs) return false;
    if (self.cur[r].node == NO_NODE) return !self.string_keyed();
    return self.rep_of(self.cur[r].node) == OptRep.INT32;
}

// Whether register `r` holds an object (or other value) in the window.
// A register holding a VALUE node.
fn bool OptBuild.holds_value(&self, uint r) {
    return r < self.nregs && self.cur[r].node != NO_NODE && self.rep_of(self.cur[r].node) == OptRep.VALUE;
}

// Whether register `r` holds a CONST_OBJ node: an object, never a number.
fn bool OptBuild.const_object(&self, uint r) {
    return r < self.nregs && self.cur[r].node != NO_NODE && self.g.nodes[self.cur[r].node].op == OptOp.CONST_OBJ;
}

// The WINDOW_CONST id of the undefined, null or boolean a STORE_CONST put in register `r`'s window
// slot, or 0.
fn char OptBuild.window_const(&self, uint r) {
    if (r >= self.nregs || self.cur[r].node != NO_NODE || self.const_def[r] == NO_NODE) return 0;
    return window_const_id(self.g.nodes[self.const_def[r]].imm);
}

// Whether register `r` holds a constant that is never a number: a CONST_OBJ node, or the
// undefined, null or boolean a STORE_CONST put in its window slot.
fn bool OptBuild.const_non_number(&self, uint r) => self.const_object(r) || self.window_const(r) != 0;

// The cc and operand slots (imm, b | c << 20) of an equality node of `kind` (0 strict, 1 strict
// negated, 2 loose, 3 loose negated) between slots rb and rc: against an undefined, null or boolean
// stored as a constant, a strict test compares the other slot with it, a loose one with undefined
// or null is the null test (kind 4, 5). `other` gets the slot tested alone, or stays as it was.
fn char OptBuild.equality_cc(&self, uint kind, uint rb, uint rc, long* imm, uint* other) {
    char kb = self.window_const(rb);
    char kc = self.window_const(rc);
    if (kb == 0 && kc == 0) return (char)kind;
    char id = kc != 0 ? kc : kb;
    uint r = kc != 0 ? rb : rc;
    if (kind >= 2 && id > 2) return (char)kind;
    *imm = (long)r | ((long)r << 20);
    *other = r;
    return kind >= 2 ? (char)(kind + 2) : (char)(kind | (id << WINDOW_CONST_SHIFT));
}

// Store the VALUE node of register `r` to its window slot if it is dirty.
fn void OptBuild.publish_value(&self, uint r) {
    if (!self.cur[r].dirty) return;
    // A VALUE node of an inlined body's slot beyond the caller's frame is never stored in the
    // normal flow, unless a boolean (see the header of opt_ir.c3): the site stays a call.
    if (self.cur_fn != 0 && r >= self.caller_regs && !self.g.is_boolean(&self.g.nodes[self.cur[r].node])) self.inline_unsafe = true;
    self.add(OptOp.STORE_VALUE, OptRep.NONE, self.cur[r].node, NO_NODE, (long)r);
    self.cur[r].dirty = false;
}

// Whether `r` can be read from the window by a node that takes no VALUE operand: holds a window
// value, or a VALUE node, which is then stored first.
fn bool OptBuild.in_window(&self, uint r) {
    if (r >= self.nregs) return false;
    if (self.cur[r].node == NO_NODE) return true;
    if (!self.holds_value(r)) return false;
    self.publish_value(r);
    return true;
}

// The read being lowered into register `ra`, beyond the caller's frame, left its value in the window,
// out of the collector's sight: the next round builds it as a VALUE node, which stays in a
// register, unless a numeric use asks for a number (OptOverride.soft). The body waits for it.
fn void OptBuild.soft_value(&self, uint ra) {
    bool asked = false;
    foreach (c : self.load_reps) asked |= c.block == self.pckey();
    if (!asked) {
        self.load_reps.push({ .block = self.pckey(), .reg = ra, .rep = OptRep.VALUE, .soft = true });
        self.load_changed = true;
    }
    self.inline_unsafe = true;
}

// The register `reg`, still in the window, was written by a property read the next round can
// build as a VALUE node.
fn void OptBuild.ask_value(&self, uint reg) {
    uint key = self.load_def[reg];
    if (key == NO_NODE) return;
    // The key names the inline site the load belongs to and its pc (OptBuild.pckey).
    uint si1 = key >> 24;
    if (si1 > (uint)self.sites.len()) return;
    CompiledFunction* kf = si1 == 0 ? self.f : self.sites[(sz)si1 - 1].cf;
    if ((key & 0xFFFFFF) >= kf.code_count) return;
    Opcode o = kf.code[key & 0xFFFFFF].op;
    // A global read is a load only in an inlined body (the function's own is a GENERIC).
    // An element read is a load only in an inlined body (the function's own is a GENERIC).
    if (o != Opcode.GETPROPC && o != Opcode.GETPROPC_CACHED && o != Opcode.GETTHISC && o != Opcode.GETCAP
        && ((o != Opcode.GETGLOBAL && o != Opcode.GETVAR && o != Opcode.GETPROP) || si1 == 0)) return;
    foreach (&c : self.load_reps) if (c.block == key) return;
    self.load_reps.push({ .block = key, .reg = reg, .rep = OptRep.VALUE });
    self.load_changed = true;
}

// The node `n` is a copy of, through any number of copies.
fn uint OptBuild.copied(&self, uint n) {
    while (n != NO_NODE && self.g.nodes[n].op == OptOp.COPY) n = self.g.nodes[n].a;
    return n;
}

// Give the guard `chk` of an inlined method call at `callee_reg` the function object its method
// read names (method_constant), and note a receiver that read already proved an object (bit 3). A
// case of a polymorphic call `s` reads it where its first test noted it.
fn void OptBuild.settle_method(&self, uint chk, uint callee_reg, CompiledFunction* cf, OptInlineSite* s = null) {
    bool proven;
    OptNode* n = &self.g.nodes[chk];
    n.key = self.method_constant(callee_reg, cf, &proven);
    if (n.key == null && s != null && s.poly && s.method_read != null) n.key = self.read_constant(s.method_read, s.method_read_pc, cf);
    if (n.key != null && proven) n.cc |= 8;
}

// The inherited read (function `f`, pc `pc`) that defined the callee register of a method call:
// the register's node, through the copies that moved it there, or the read into its slot.
// `read_from_receiver`: the read's receiver node is the call's.
fn bool OptBuild.method_read(&self, uint callee_reg, CompiledFunction** f, uint* pc, bool* read_from_receiver) {
    *read_from_receiver = false;
    if (callee_reg + 1 >= self.nregs) return false;
    uint n = self.copied(self.cur[callee_reg].node);
    if (n != NO_NODE) {
        OptNode* load = &self.g.nodes[n];
        if (load.op != OptOp.LOAD_FIELD || load.cc != 2) return false;
        *f = self.g.fns[load.fidx].f;
        *pc = load.pc;
        // The read proved its receiver an object: the call's, when that is the same node.
        *read_from_receiver = load.b != NO_NODE && self.copied(load.b) == self.copied(self.cur[callee_reg + 1].node);
        return true;
    }
    uint key = self.load_def[callee_reg];
    uint site = key >> 24;
    if (key == NO_NODE || site > (uint)self.sites.len()) return false;
    *f = site == 0 ? self.f : self.sites[(sz)site - 1].cf;
    *pc = key & 0xFFFFFF;
    return true;
}

// The function object in the callee register of a method call about to be inlined, when the read
// that defined the register (method_read) names one under the prototype epoch as it stands
// (read_constant); else null.
fn HObject* OptBuild.method_constant(&self, uint callee_reg, CompiledFunction* cf, bool* read_from_receiver) {
    CompiledFunction* f;
    uint pc;
    if (!self.method_read(callee_reg, &f, &pc, read_from_receiver)) return null;
    return self.read_constant(f, pc, cf);
}

// A closure of `cf` the call's guard would pass now that the inherited read at `pc` of `f` reads
// under the prototype epoch as it stands, of any receiver its cache entry settled: the one it holds
// and those it retained (hobject::ICProtoSet). Else null. The guard compares the callee with it.
// It is observed, so its death moves the epoch: while the epoch stands, its address names it alone.
fn HObject* OptBuild.read_constant(&self, CompiledFunction* f, uint pc, CompiledFunction* cf) {
    if (pc >= f.code_count || f.ic_entries == null) return null;
    Opcode op = f.code[pc].op;
    if (op != Opcode.GETPROPC && op != Opcode.GETPROPC_CACHED && op != Opcode.GETTHISC) return null;
    // The cache entry is that of the read's last word.
    bytecode::DecodedBytecode d = bytecode::decode_bytecode(f.code, f.code_count, pc);
    if (!d.valid || d.next_pc <= pc) return null;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[d.next_pc - 1];
    hobject::ICChainEpoch* e = opt_epoch_entry(self.h, ic);
    if (e == null) return null;
    HObject* fo = constant_callee(e.owner.prop_values()[ic.prop_idx].get(), cf);
    hobject::ICProtoSet* set = ic.chain.protos;
    if (fo != null || set == null || set.epoch != e.value) return fo;
    for (uint k = 0; k < set.count && fo == null; k++) {
        hobject::ICProtoCase* other = &set.cases[k];
        if (other.owner != null && other.idx < other.owner.prop_count) fo = constant_callee(other.owner.prop_values()[other.idx].get(), cf);
    }
    return fo;
}

// `v` when it is a closure of `cf` that CHECK_CALLEE's tests pass, observed so that its death moves
// the prototype epoch the guard compares; else null.
fn HObject* constant_callee(TVal v, CompiledFunction* cf) {
    if (!v.is_object()) return null;
    HObject* fo = (HObject*)v.get_heapptr();
    if (fo.callable_kind() != hobject::CallableKind.COMPILED_FN || fo.flags.exotic_proxyobj || fo.flags.obj_class != hobject::ObjClass.FUNCTION) return null;
    hobject::HObjectFunction* fx = &(*fo.extra_ptr()).func;
    if (fx.comp_func != cf || fx.var_env == null || (fx.lex_env != null && fx.lex_env.flags.is_with)) return null;
    fo.gc.prototype_observed = true;
    return fo;
}

// The cache entry of the instruction being lowered when it names an own data property of a
// plain object that the optimized code can read by slot, else null.
fn hobject::ICEntry* OptBuild.own_field(&self, bool inherited = false) {
    CompiledFunction* f = self.cur_f();
    if (f.ic_entries == null) { self.h.opt.field_skipped[OptFieldSkip.NO_CACHE.ordinal]++; return null; }
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[self.next_pc - 1];
    void* key = (void*)ic.key.borrow();
    if (key == null || ic.shape_id == heap::SHAPE_NONE) { self.h.opt.field_skipped[OptFieldSkip.NO_CACHE.ordinal]++; return null; }
    // A site that has exited repeatedly is left to the baseline's cache.
    if (opt_site_banned(self.f, f, self.next_pc - 1)) { self.h.opt.field_skipped[OptFieldSkip.BANNED.ordinal]++; return null; }
    // A read may also name a data property of a prototype, by the epoch guard or link snapshot of the baseline.
    bool proto = inherited && ic.has_proto && ic.prop_idx != hobject::IC_PROP_MISSING
        && (ic.chain_len == hobject::IC_CHAIN_EPOCH || (ic.chain_len > 0 && (uint)ic.chain_len <= hobject::IC_MAX_CHAIN));
    if (ic.has_proto && !proto) { self.h.opt.field_skipped[OptFieldSkip.PROTO.ordinal]++; return null; }
    if (!proto && ic.chain_len != 0 && ic.chain_len != hobject::IC_CHAIN_POLY) { self.h.opt.field_skipped[OptFieldSkip.CHAIN.ordinal]++; return null; }
    if (ic.prop_idx == hobject::IC_PROP_ABSENT || ic.prop_flags.is_accessor) { self.h.opt.field_skipped[OptFieldSkip.ABSENT.ordinal]++; return null; }
    if (key == (void*)self.h.strs[heap::BuiltinStr.LENGTH]) { self.h.opt.field_skipped[OptFieldSkip.LENGTH.ordinal]++; return null; }
    if (self.w.op != Opcode.GETTHISC) {
        if (self.w.c >= f.const_count || !f.constants[self.w.c].is_string()) { self.h.opt.field_skipped[OptFieldSkip.KEY.ordinal]++; return null; }
        if (f.constants[self.w.c].get_heapptr() != key) { self.h.opt.field_skipped[OptFieldSkip.KEY.ordinal]++; return null; }
    }
    if (proto) return ic;
    // More shapes than the code compares leave the site to the baseline.
    OptPoly p;
    if (!field_shapes(ic, &p)) { self.h.opt.field_skipped[OptFieldSkip.POLY_FULL.ordinal]++; return null; }
    return ic;
}

// The cache entry of the PUTTHISC being lowered when it holds an add of the instruction's key: an
// absent-property entry of the current shape recycle epoch. The emitted code checks the rest at run
// time (OptCg.emit_add_field).
fn hobject::ICEntry* OptBuild.absent_field(&self) {
    CompiledFunction* f = self.cur_f();
    if (f.ic_entries == null || self.w.op != Opcode.PUTTHISC) return null;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[self.next_pc - 1];
    void* key = (void*)ic.key.borrow();
    if (key == null || ic.prop_idx != hobject::IC_PROP_ABSENT || ic.has_proto) return null;
    if (ic.shape_gen != self.h.shape_recycle_epoch || (uint)ic.chain_len > hobject::IC_MAX_CHAIN) return null;
    if (self.w.c >= f.const_count || !f.constants[self.w.c].is_string() || f.constants[self.w.c].get_heapptr() != key) return null;
    return ic;
}

// Whether the field instruction being lowered has never run: its cache was never filled. A flat
// body leaves such an instruction as an unconditional exit to the callee's baseline code.
fn bool OptBuild.cold_field(&self) {
    switch (self.w.op) {
        case GETPROPC: case GETPROPC_CACHED: case GETTHISC: case PUTPROPC: case PUTTHISC:
            CompiledFunction* f = self.cur_f();
            if (f.ic_entries == null) return false;
            hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[self.next_pc - 1];
            return (void*)ic.key.borrow() == null;
        case GETGLOBAL: case GETVAR:
            CompiledFunction* f = self.cur_f();
            if (f.var_ic_entries == null) return false;
            return ((hobject::VarICEntry*)f.var_ic_entries)[self.next_pc - 1].env == null;
        default:
            return false;
    }
}

// The distinct receiver shapes the entry `ic` of an own data property caches, the entry's own
// first and then its polymorphic set, each with its slot. False when there are more than
// OPT_POLY_MAX.
fn bool field_shapes(hobject::ICEntry* ic, OptPoly* p) {
    p.count = 1;
    p.shape[0] = ic.shape_id;
    p.idx[0] = ic.prop_idx;
    if (ic.chain_len != hobject::IC_CHAIN_POLY) return true;
    hobject::ICPolySet* set = &ic.chain.poly;
    for (uint i = 0; i < set.count; i++) {
        bool dup = false;
        for (uint k = 0; k < p.count; k++) dup = dup || p.shape[k] == set.shapes[i];
        if (dup) continue;
        if (p.count == OPT_POLY_MAX) return false;
        p.shape[p.count] = set.shapes[i];
        p.idx[p.count] = set.prop_idx[i];
        p.count++;
    }
    return true;
}

// Record the shapes of the entry `ic` for the node `n` being lowered.
fn void OptBuild.set_poly(&self, uint n, hobject::ICEntry* ic) {
    OptPoly p;
    field_shapes(ic, &p);
    self.g.polys.push(p);
    self.g.nodes[n].poly = (uint)self.g.polys.len();
}

// GETPROPC, GETPROPC_CACHED and GETTHISC of an own property by the shape its cache holds: a
// typed load when a numeric use asked for one, else a read into the window.
fn bool OptBuild.get_field(&self) {
    if (self.length_site()) return self.get_length();
    hobject::ICEntry* ic = self.own_field(true);
    if (ic == null) return self.generic();
    uint recv = self.field_receiver();
    uint rnode = NO_NODE;
    if (self.w.op != Opcode.GETTHISC) {
        if (self.holds_value(recv)) {
            rnode = self.cur[recv].node;
        } else if (self.in_window(recv)) {
            self.ask_value(recv);
        } else {
            return self.generic();
        }
    } else if (self.cur_fn != 0 && self.holds_value(recv)) {
        // The receiver of a nested call held in a VALUE node.
        rnode = self.cur[recv].node;
    }
    void* key = (void*)ic.key.borrow();
    uint rkey = self.copied(rnode);
    uint ra = self.w.a;
    // Nothing since an earlier read or write of the field can have changed it: its node is the
    // value, when it has the rep a use asked of this read.
    uint held = self.held_field(key, rkey, recv);
    OptRep want;
    if (held != NO_NODE && ra < self.nregs && (!self.asked_rep(&want) || want == self.rep_of(held))) {
        self.set(ra, self.g.nodes[held].is_const() ? held : self.add(OptOp.COPY, self.rep_of(held), held));
        if (rkey != NO_NODE || recv != ra) self.note_field(key, rkey, recv, self.cur[ra].node);
        return true;
    }
    // A property of a prototype is read through the entry at run time, with no shape fact, unless
    // the entry has only ever held the one receiver (OptNode.exact). An inlined body's entry is
    // shared by every caller, and its exits do not teach it.
    bool inherited = ic.has_proto;
    bool mono = ic.chain_len == 0;
    bool exact = inherited && self.cur_fn == 0 && self.w.op != Opcode.GETTHISC && opt_settled_shape(self.h, ic) != null && ic.chain.protos == null;
    bool known = mono && self.guards_known(recv, ic.shape_id);
    uint shape = ic.shape_id;
    uint n = self.typed_load(OptOp.LOAD_FIELD, NO_NODE);
    if (n == NO_NODE) {
        n = self.add(OptOp.LOAD_FIELD, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
        self.snapshot(n);
        self.g.nodes[n].home = ra;
        self.kill(ra);
        if (ra < self.nregs) self.load_def[ra] = self.pckey();
        // A value of any kind in a slot beyond the caller's frame would be out of the collector's
        // sight: the next round builds the read as a VALUE node, which stays in a register, unless
        // a numeric use asks for a number.
        if (self.cur_fn != 0 && ra >= self.caller_regs) self.soft_value(ra);
    }
    self.g.nodes[n].cc = inherited ? 2 : (known ? 1 : 0);
    self.g.nodes[n].exact = exact;
    self.g.nodes[n].b = rnode;
    self.g.nodes[n].key = key;
    self.set_poly(n, ic);
    if (mono || exact) self.learn(recv, shape);
    // The load may have overwritten its own receiver register.
    if (recv < self.nregs && recv == ra) self.fact_shape[recv] = heap::SHAPE_NONE;
    if (self.g.nodes[n].rep != OptRep.NONE && (rkey != NO_NODE || recv != ra)) self.note_field(key, rkey, recv, n);
    return true;
}

// Whether the instruction being lowered is a GETPROPC or GETPROPC_CACHED of the constant key
// `length` that has not exited repeatedly. The baseline reads an array's length before its cache
// and records nothing, so the read is taken for an array's; a string's leaves through the exit,
// and the ban that follows lowers the site generically.
fn bool OptBuild.length_site(&self) {
    if (self.w.op != Opcode.GETPROPC && self.w.op != Opcode.GETPROPC_CACHED) return false;
    CompiledFunction* f = self.cur_f();
    if (self.w.c >= f.const_count || !f.constants[self.w.c].is_string()) return false;
    if (f.constants[self.w.c].get_heapptr() != (void*)self.h.strs[heap::BuiltinStr.LENGTH]) return false;
    return !opt_site_banned(self.f, f, self.next_pc - 1);
}

// The `length` of an array (OptBuild.length_site), as an INT32 node.
fn bool OptBuild.get_length(&self) {
    uint recv = self.w.b;
    uint rnode = NO_NODE;
    if (self.holds_value(recv)) {
        rnode = self.cur[recv].node;
    } else if (self.in_window(recv)) {
        self.ask_value(recv);
    } else {
        return self.generic();
    }
    if (self.w.a >= self.nregs) return self.generic();
    uint n = self.add(OptOp.LOAD_LENGTH, OptRep.INT32, NO_NODE, rnode, (long)self.pc);
    self.snapshot(n);
    self.set(self.w.a, n);
    return true;
}

// A CALL of Array.prototype.push with one argument (opt_push_site): a CHECK_BUILTIN of the callee,
// then an ARRAY_PUSH of the argument onto the receiver, whose result is the new length. In an
// inlined body an operand beyond the caller's frame must be a VALUE node; one a read left in the
// window asks for that in the next round.
fn bool OptBuild.push_call(&self) {
    if (self.w.op != Opcode.CALL || self.wide || !opt_push_site(self.h, self.cur_f(), self.next_pc - 1)) return false;
    if (opt_site_banned(self.f, self.cur_f(), self.next_pc - 1)) return false;
    uint callee = self.w.b;
    uint ra = self.w.a;
    if (callee + 2 >= self.nregs || ra >= self.nregs) return false;
    uint[3] nodes;
    for (uint k = 0; k < 3; k++) {
        uint r = callee + k;
        nodes[k] = NO_NODE;
        if (self.cur[r].node != NO_NODE && (k == 2 || self.holds_value(r))) {
            nodes[k] = self.cur[r].node;
        } else if (self.cur_fn != 0 && r >= self.caller_regs) {
            if (!self.call_operand(r, &nodes[k])) return self.cur_fn == 0 ? false : self.generic();
        } else if (!self.in_window(r)) {
            return self.cur_fn == 0 ? false : self.generic();
        }
    }
    uint chk = self.add(OptOp.CHECK_BUILTIN, OptRep.NONE, nodes[0], NO_NODE, (long)builtins::Builtin.ARRAY_PROTO_PUSH.ordinal);
    self.g.nodes[chk].home = callee;
    self.snapshot(chk);
    uint n = self.add(OptOp.ARRAY_PUSH, OptRep.INT32, nodes[2], nodes[1], (long)self.pc);
    self.snapshot(n);
    self.set(ra, n);
    // The array's storage may have moved.
    self.forget_facts();
    self.builtin_calls++;
    return true;
}

// The Math function of builtin number `builtin`.
fn bool opt_math_of(uint builtin, OptMath* m) {
    if (builtin >= builtins::Builtin::values.len) return false;
    switch ((builtins::Builtin)builtin) {
        case MATH_ABS: *m = ABS;
        case MATH_FLOOR: *m = FLOOR;
        case MATH_CEIL: *m = CEIL;
        case MATH_ROUND: *m = ROUND;
        case MATH_SQRT: *m = SQRT;
        case MATH_MIN: *m = MIN;
        case MATH_MAX: *m = MAX;
        case MATH_POW: *m = POW;
        case MATH_SIN: *m = SIN;
        case MATH_COS: *m = COS;
        case MATH_TAN: *m = TAN;
        case MATH_EXP: *m = EXP;
        case MATH_LOG: *m = LOG;
        case MATH_ATAN: *m = ATAN;
        case MATH_ATAN2: *m = ATAN2;
        default: return false;
    }
    return true;
}

// A CALL or CALL_UNDEF_THIS of the Math function the site has always called (hobject::IC_BUILTIN_TARGET) with as many
// arguments as it takes: a CHECK_BUILTIN of the callee, then a MATH node over the arguments as
// numbers. FLOOR, CEIL and ROUND of an INT32 are the INT32 itself; ABS, MIN and MAX of INT32s stay
// INT32 until ABS has overflowed there.
fn bool OptBuild.math_call(&self) {
    if ((self.w.op != Opcode.CALL && self.w.op != Opcode.CALL_UNDEF_THIS) || self.wide) return false;
    CompiledFunction* f = self.cur_f();
    if (f.ic_entries == null) return false;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[self.next_pc - 1];
    if (hobject::ic_call_count(ic) != 1 || (ic.prop_idx & hobject::IC_BUILTIN_TARGET) == 0) return false;
    uint builtin = ic.prop_idx & ~hobject::IC_BUILTIN_TARGET;
    OptMath m;
    if (!opt_math_of(builtin, &m) || self.w.c != m.args) return false;
    if (opt_site_banned(self.f, f, self.next_pc - 1)) return false;
    uint callee = self.w.b;
    uint ra = self.w.a;
    if (callee + 1 + m.args >= self.nregs || ra >= self.nregs) return false;
    if (self.cur_fn != 0 && callee + 1 + m.args >= self.caller_regs) return false;
    uint cnode = NO_NODE;
    if (self.holds_value(callee)) {
        cnode = self.cur[callee].node;
    } else if (!self.in_window(callee)) {
        return false;
    }
    bool ints = m == ABS || m == MIN || m == MAX || m == FLOOR || m == CEIL || m == ROUND;
    if (m == ABS && (ic.feedback & hobject::FB_OVF) != 0) ints = false;
    for (uint k = 0; k < m.args; k++) {
        uint r = callee + 2 + k;
        if (self.holds_value(r)) return false;
        if (self.cur[r].node == NO_NODE || self.rep_of(self.cur[r].node) != OptRep.INT32) ints = false;
    }
    uint chk = self.add(OptOp.CHECK_BUILTIN, OptRep.NONE, cnode, NO_NODE, (long)builtin);
    self.g.nodes[chk].home = callee;
    self.snapshot(chk);
    OptRep rep = ints ? OptRep.INT32 : OptRep.FLOAT64;
    uint x = self.operand(callee + 2, rep);
    uint y = m.args == 2 ? self.operand(callee + 3, rep) : NO_NODE;
    if (x == NO_NODE || (m.args == 2 && y == NO_NODE)) return self.refuse(OptRefuse.FUNCTION);
    self.builtin_calls++;
    if (ints && (m == FLOOR || m == CEIL || m == ROUND)) {
        self.set(ra, x);
        return true;
    }
    uint n = self.add(OptOp.MATH, rep, x, y, (long)m.ordinal);
    if (ints && m == ABS) self.snapshot(n);
    self.set(ra, n);
    return true;
}

// PUTPROPC and PUTTHISC of an own writable data property by the shape its cache holds, from an
// object in the window; a numeric value is stored without being published first.
fn bool OptBuild.put_field(&self) {
    hobject::ICEntry* ic = self.own_field();
    bool this_op = self.w.op == Opcode.PUTTHISC;
    // A forwarded receiver is typically the object an inlined constructor is building.
    if ((ic == null || !ic.prop_flags.writable) && this_op && self.cur_fn != 0
        && (self.sites[self.cur_site].construct || self.sites[self.cur_site].forward || self.sites[self.cur_site].dotcall)) return self.add_field();
    if (ic == null || !ic.prop_flags.writable) return self.generic();
    uint recv = self.field_receiver();
    uint rnode = NO_NODE;
    if (!this_op) {
        if (self.holds_value(recv)) {
            rnode = self.cur[recv].node;
        } else if (!self.in_window(recv)) {
            return self.generic();
        }
    } else if (self.cur_fn != 0 && self.holds_value(recv)) {
        rnode = self.cur[recv].node;
    }
    uint rv = this_op ? self.w.a : self.w.b;
    // A constant is stored as one. A value with no node is stored from the window, through the
    // counted and traced store when it is a heap value (OptCg.store_slot_value); a property read
    // that defined it is built as a VALUE node in the next round.
    if (rv >= self.nregs) return self.generic();
    uint value = self.cur[rv].node != NO_NODE ? self.cur[rv].node : self.const_def[rv];
    if (value == NO_NODE) self.ask_value(rv);
    uint n = self.add(OptOp.STORE_FIELD, OptRep.NONE, value, rnode, (long)self.pc);
    self.snapshot(n);
    void* key = (void*)ic.key.borrow();
    self.g.nodes[n].key = key;
    bool mono = ic.chain_len == 0;
    self.g.nodes[n].cc = (mono && self.guards_known(recv, ic.shape_id)) ? 1 : 0;
    self.set_poly(n, ic);
    if (mono) self.learn(recv, ic.shape_id);
    // The field of any receiver may be the one written; this one now reads back the value.
    self.drop_key(key);
    if (self.cur[rv].node != NO_NODE) self.note_field(key, self.copied(rnode), recv, self.cur[rv].node);
    return true;
}

// PUTTHISC of an inlined constructor that adds its key to the object the inline allocated, held in
// the receiver slot as a VALUE node.
fn bool OptBuild.add_field(&self) {
    uint recv = self.field_receiver();
    uint rv = self.w.a;
    hobject::ICEntry* ic = self.absent_field();
    if (ic == null || !self.holds_value(recv) || rv >= self.nregs) return self.generic();
    uint value = self.cur[rv].node;
    // A window value is read from its slot, which lies in the caller's frame (beyond it there are
    // only nodes, see OptBuild.inline_unsafe).
    if (value == NO_NODE && rv >= self.caller_regs) return self.generic();
    uint n = self.add(OptOp.ADD_FIELD, OptRep.NONE, value, self.cur[recv].node, (long)self.pc);
    self.snapshot(n);
    self.g.nodes[n].key = (void*)ic.key.borrow();
    self.add_known(n, self.cur[recv].node, (void*)ic.key.borrow());
    // The object's shape changed, under whatever register a fact names it by.
    self.forget_facts();
    return true;
}

// The receiver register `r` of an element access: a window value, or in an inlined body a VALUE
// node of a slot beyond the caller's frame, which `node` receives (it is never stored, so the access
// takes it from its machine register). Any other VALUE node is stored first.
fn bool OptBuild.elem_receiver(&self, uint r, uint* node) {
    *node = NO_NODE;
    if (self.cur_fn != 0 && r >= self.caller_regs && self.holds_value(r)) {
        *node = self.cur[r].node;
        return true;
    }
    // A receiver a property or global read left in a slot beyond the frame: the next round builds
    // that read as a VALUE node.
    if (self.cur_fn != 0 && r >= self.caller_regs && r < self.nregs && self.cur[r].node == NO_NODE) self.ask_value(r);
    return self.in_window(r);
}

// The element access of the object in register `r` being lowered, by node `n`: it knows the object
// an array (cc ELEM_KNOWN) when an earlier access proved what this one needs (`store`: an array
// without indexed named properties), and proves that for the accesses after it when it leaves for
// any other object (opt_elem_arrays_only). Called before the node's result is set, which drops the
// fact when it overwrites `r`.
fn void OptBuild.elem_fact(&self, uint r, uint n, bool store) {
    if (r >= self.nregs) return;
    char need = store ? ELEM_ARRAY_STORE : ELEM_ARRAY;
    if (self.fact_elem[r] >= need) self.g.nodes[n].cc |= ELEM_KNOWN;
    if (opt_elem_arrays_only(self.cur_f(), self.next_pc - 1)) self.fact_elem[r] = max(self.fact_elem[r], need);
}

// GETPROP of an element at an integer index, from an object in the window.
fn bool OptBuild.get_elem(&self) {
    uint rnode;
    // A site that has exited repeatedly (a hole, an index past the end) runs the baseline's access.
    if (opt_site_banned(self.f, self.cur_f(), self.next_pc - 1)) return self.generic();
    OptView view;
    uint cv = self.const_view(self.w.b, false, &view);
    if (cv != NO_NODE && self.w.a < self.nregs && self.index_ok(self.w.c)) {
        // An element of a constant typed array, read as the number it is.
        TypedKind kind = TYPED_KINDS[view.kind];
        bool wide = kind.is_float() || kind.cls == hobject::ObjClass.UINT32ARRAY;
        uint idx = self.operand(self.w.c, OptRep.INT32);
        if (idx == NO_NODE) return self.generic();
        uint n = self.add(OptOp.LOAD_ELEM, wide ? OptRep.FLOAT64 : OptRep.INT32, idx, NO_NODE, (long)self.pc);
        self.g.nodes[n].c = cv;
        self.snapshot(n);
        self.set(self.w.a, n);
        return true;
    }
    if (!self.elem_receiver(self.w.b, &rnode) || !self.index_ok(self.w.c)) return self.generic();
    OptRep rep;
    if (self.asked_rep(&rep)) {
        uint idx = self.operand(self.w.c, OptRep.INT32);
        if (idx == NO_NODE) return self.generic();
        uint n = self.add(OptOp.LOAD_ELEM, rep, idx, NO_NODE, (long)self.pc);
        self.g.nodes[n].c = rnode;
        self.elem_fact(self.w.b, n, false);
        self.snapshot(n);
        self.set(self.w.a, n);
        return true;
    }
    // The element read into the window; in an inlined body, a slot beyond the caller's frame would
    // be out of the collector's sight.
    uint ra = self.w.a;
    uint idx = self.operand(self.w.c, OptRep.INT32);
    if (ra >= self.nregs || idx == NO_NODE) return self.generic();
    uint n = self.add(OptOp.LOAD_ELEM, OptRep.NONE, idx, NO_NODE, (long)self.pc);
    self.g.nodes[n].c = rnode;
    self.elem_fact(self.w.b, n, false);
    self.snapshot(n);
    self.kill(ra);
    self.load_def[ra] = self.pckey();
    if (self.cur_fn != 0 && ra >= self.caller_regs) self.soft_value(ra);
    return true;
}

// PUTPROP of a value to an element at an integer index, into an object in the window. A numeric
// node is stored as it is; any other value is read from the window, in an inlined body only (a
// function's own body runs it as a GENERIC), and stored with the baseline's counted store.
fn bool OptBuild.put_elem(&self) {
    uint rv = self.w.c;
    uint rnode;
    if (opt_site_banned(self.f, self.cur_f(), self.next_pc - 1)) return self.generic();
    if (rv >= self.nregs || !self.index_ok(self.w.b)) return self.generic();
    OptView view;
    uint cv = self.const_view(self.w.a, true, &view);
    if (cv != NO_NODE && !self.holds_value(rv)) {
        // A number stored into a constant typed array: an integer kind takes ToInt32 of it (its low
        // bits are those of the narrower conversions), a float kind the double.
        uint idx = self.operand(self.w.b, OptRep.INT32);
        uint val = self.operand(rv, TYPED_KINDS[view.kind].is_float() ? OptRep.FLOAT64 : OptRep.INT32);
        if (idx == NO_NODE || val == NO_NODE) return self.generic();
        uint n = self.add(OptOp.STORE_ELEM, OptRep.NONE, idx, val, (long)self.pc);
        self.g.nodes[n].c = cv;
        self.snapshot(n);
        return true;
    }
    bool node = self.cur[rv].node != NO_NODE;
    if (!node && self.load_def[rv] != NO_NODE) {
        // A copy between typed arrays (a[i] = b[j]) has no numeric use to ask its read for a
        // number: the store asks for the one its array holds, and the next round has the node.
        OptRep want = self.typed_store_rep();
        if (want != OptRep.NONE) self.ask_load(self.load_def[rv], rv, want);
    }
    if (!node && (self.cur_fn == 0 || !self.in_window(rv))) return self.generic();
    if (!self.elem_receiver(self.w.a, &rnode)) return self.generic();
    uint idx = self.operand(self.w.b, OptRep.INT32);
    if (idx == NO_NODE) return self.generic();
    uint n = self.add(OptOp.STORE_ELEM, OptRep.NONE, idx, self.cur[rv].node, (long)self.pc);
    self.g.nodes[n].c = rnode;
    self.elem_fact(self.w.a, n, true);
    self.snapshot(n);
    return true;
}

// The rep a store to the element at this instruction takes without a conversion, by the typed
// array class its baseline code recorded: INT32 for an integer kind, FLOAT64 for a float one, and
// NONE for no record, another class, or Uint8Clamped (whose stores round).
fn OptRep OptBuild.typed_store_rep(&self) {
$if features::BUFFERS:
    CompiledFunction* f = self.cur_f();
    if (f.ic_entries == null) return OptRep.NONE;
    long recorded = (long)((hobject::ICEntry*)f.ic_entries)[self.next_pc - 1].fwd_callee & ~(long)ELEM_CLASS_SEEN;
    if (recorded == 0) return OptRep.NONE;
    // Layout.class_mask: the class field is bits 16..21.
    long cls = (recorded >> 16) & 0x3F;
    foreach (kind : TYPED_KINDS) {
        if ((long)kind.cls.ordinal != cls) continue;
        switch (kind.cls) {
            case UINT8CLAMPEDARRAY: return OptRep.NONE;
            case FLOAT32ARRAY: case FLOAT64ARRAY: return OptRep.FLOAT64;
            default: return OptRep.INT32;
        }
    }
    return OptRep.NONE;
$else
    return OptRep.NONE;
$endif
}

// UNM of a number, as a double.
fn bool OptBuild.negate(&self) {
    char fb = self.feedback();
    if ((fb & (hobject::FB_STR | hobject::FB_OTHER)) != 0) return self.generic();
    uint x = self.operand(self.w.b, OptRep.FLOAT64);
    if (x == NO_NODE) return self.generic();
    self.set(self.w.a, self.add(OptOp.NEG_F64, OptRep.FLOAT64, x));
    return true;
}

// A % B of two int32 values; the emitter exits for a negative dividend and a divisor of zero or
// below, so the remainder is never -0, NaN or a double.
fn bool OptBuild.modulo(&self) {
    if ((self.feedback() & hobject::FB_OPERANDS) != 0 || self.state_float(self.w.b) || self.state_float(self.w.c)) return self.generic();
    uint x = self.operand(self.w.b, OptRep.INT32);
    uint y = self.operand(self.w.c, OptRep.INT32);
    if (x == NO_NODE || y == NO_NODE) return self.generic();
    if (self.g.nodes[y].op == OptOp.CONST_I32 && self.g.nodes[y].imm <= 0) return self.generic();
    uint n = self.add(OptOp.MOD_I32, OptRep.INT32, x, y);
    self.snapshot(n);
    self.set(self.w.a, n);
    return true;
}

// EQ, NEQ, SEQ, SNEQ, LT, LE, GT, GE producing a boolean: stored to the window slot of A.
fn bool OptBuild.compare_value(&self) {
    Opcode op = self.w.op;
    uint ra = self.w.a;
    uint rb = self.w.b;
    uint rc = self.w.c;
    if (ra >= self.nregs || rb >= self.nregs || rc >= self.nregs) return self.generic();
    bool equality = op.ordinal < Opcode.LT.ordinal;
    char fb = self.feedback();
    // A folded constant that is not a number says as much as the feedback.
    bool non_number = (fb & (hobject::FB_STR | hobject::FB_OTHER)) != 0 || self.const_non_number(rb) || self.const_non_number(rc);
    if (equality) {
        if (self.holds_value(rb)) self.publish_value(rb);
        if (self.holds_value(rc)) self.publish_value(rc);
    } else if (non_number) {
        return self.generic();
    }
    bool numeric_b = self.cur[rb].node != NO_NODE && !self.holds_value(rb);
    bool numeric_c = self.cur[rc].node != NO_NODE && !self.holds_value(rc);
    if (equality && non_number) {
        // Values the number path would only exit on: the baseline's equality test on the window.
        if (numeric_b || numeric_c) return self.generic();
        uint kind = op == Opcode.SEQ ? 0 : (op == Opcode.SNEQ ? 1 : (op == Opcode.EQ ? 2 : 3));
        long imm = (long)rb | ((long)rc << 20);
        uint other = NO_NODE;
        char cc = self.equality_cc(kind, rb, rc, &imm, &other);
        uint n = self.add(OptOp.COMPARE_WINDOW, OptRep.NONE, NO_NODE, NO_NODE, imm);
        self.g.nodes[n].cc = cc;
        self.g.nodes[n].home = ra;
        self.snapshot(n);
        self.kill(ra);
        return true;
    }
    OptRep rep = self.arith_rep(rb, rc);
    if (rep == OptRep.NONE) return self.generic();
    uint x = self.operand(rb, rep);
    uint y = self.operand(rc, rep);
    if (x == NO_NODE || y == NO_NODE) return self.generic();
    uint row = equality ? ((op == Opcode.EQ || op == Opcode.SEQ) ? 8 : 9) : 4 + op.ordinal - Opcode.LT.ordinal;
    uint n = self.add(OptOp.COMPARE, OptRep.VALUE, x, y, (long)rep.ordinal);
    self.g.nodes[n].cc = (char)row;
    self.set(ra, n);
    return true;
}

// `A = !B`: a boolean node when B is a number or a boolean, else stored to the window slot of A.
fn bool OptBuild.not_value(&self) {
    uint ra = self.w.a;
    uint rb = self.w.b;
    if (ra >= self.nregs || rb >= self.nregs) return self.generic();
    uint node = self.truth_operand(rb);
    uint n = self.add(OptOp.LNOT, node == NO_NODE ? OptRep.NONE : OptRep.VALUE, node, NO_NODE, (long)rb);
    // (A known operand cannot exit, but the test hook exits at any LNOT, with the frame it describes.)
    self.snapshot(n);
    if (node == NO_NODE) {
        self.g.nodes[n].home = ra;
        self.kill(ra);
    } else {
        self.set(ra, n);
    }
    return true;
}

// The node whose truth a test of register `r` reads, a number or a boolean; NO_NODE for a value
// in the window, where any other VALUE node is stored first.
fn uint OptBuild.truth_operand(&self, uint r) {
    uint node = self.cur[r].node;
    if (!self.holds_value(r) || self.g.is_boolean(&self.g.nodes[node])) return node;
    self.publish_value(r);
    return NO_NODE;
}

// THROW in an inlined body is a cold path: leave for the callee's baseline code, which throws.
fn bool OptBuild.throw_exit(&self) {
    if (self.cur_fn == 0 || !self.sites[self.cur_site].flat) return self.generic();
    uint n = self.add(OptOp.EXIT, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
    self.snapshot(n);
    self.cold_exit = true;
    self.cold_site = self.cur_site;
    return true;
}

// An exit node of a region: the code after the loop continues in the baseline code.
fn bool OptBuild.region_exit(&self) {
    uint n = self.add(OptOp.EXIT, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
    self.g.nodes[n].cc = OPT_EXIT_LEAVE;
    self.snapshot(n);
    self.cold_exit = true;
    return true;
}

// TYPEOF in an inlined body: the interned name of the operand's tag, as the baseline answers it out
// of line. A numeric operand's name is `number` with no test. The function's own TYPEOF stays a
// GENERIC.
fn bool OptBuild.typeof_value(&self) {
    if (self.cur_fn == 0) return self.generic();
    uint ra = self.w.a;
    uint rb = self.w.b;
    if (ra >= self.nregs || rb >= self.nregs) return self.generic();
    uint rnode = NO_NODE;
    // A number's name is known here: an int32 or a double read as such, never a window value.
    bool number = self.cur[rb].node != NO_NODE && !self.holds_value(rb);
    if (!number && self.holds_value(rb)) rnode = self.cur[rb].node;
    uint n = self.add(OptOp.TYPEOF, OptRep.NONE, rnode, NO_NODE, (long)rb);
    self.g.nodes[n].home = ra;
    self.g.nodes[n].cc = number ? 1 : 0;
    self.snapshot(n);
    self.kill(ra);
    return true;
}

// NEWOBJ, NEWOBJ_SHAPE, NEWARR or NEWARR_CONST in an inlined body: the object the baseline emitter
// allocates inline, into the body's slot. A case the inline allocator does not cover keeps the call.
fn bool OptBuild.alloc_value(&self) {
    if (self.cur_fn == 0) return self.generic();
    uint ra = self.w.a;
    if (ra >= self.nregs || !inline_alloc_ok()) return self.generic();
    CompiledFunction* f = self.cur_f();
    uint count = self.w.get_bc();
    switch (self.w.op) {
        case NEWOBJ:
            break;
        case NEWOBJ_SHAPE:
            hobject::Shape* shape = self.h.get_shape(count);
            if (shape == null || shape.offset + shape.own_count > hobject::SHAPED_INLINE_MAX_PROPS) return self.generic();
        case NEWARR:
            if (count == 0 || count > hobject::ARRAY_INLINE_MAX_CAPACITY) return self.generic();
        case NEWARR_CONST:
            if (f.constants == null || count >= f.const_count || !f.constants[count].is_fastint()) return self.generic();
            uint length = (uint)f.constants[count].get_fastint();
            if (length == 0 || length > hobject::ARRAY_INLINE_MAX_CAPACITY) return self.generic();
        default:
            return self.generic();
    }
    // The object lives in the callee's slot: an exit publishes the frame that scans it, and the
    // allocator made it a temporary root, so no collection can see a stale slot (see opt_ir.c3).
    uint n = self.add(OptOp.ALLOC, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
    self.snapshot(n);
    self.g.nodes[n].home = ra;
    self.kill(ra);
    return true;
}

// An INIT_SLOT, of an inlined body or of the function's own: the slot index is the instruction's
// immediate, so the value and the object are taken as nodes where the graph holds them and from the
// window otherwise. It defines no register, which is why the baseline emitter runs it as a GENERIC
// only here: its effect on the file is nothing.
fn bool OptBuild.init_slot(&self) {
    uint ra = self.w.a;
    uint rc = self.w.c;
    if (ra >= self.nregs || rc >= self.nregs) return self.generic();
    uint obj = NO_NODE;
    uint value = NO_NODE;
    // A numeric node in the object's register is not an object.
    if (self.cur[ra].node != NO_NODE) {
        if (!self.holds_value(ra)) return self.generic();
        obj = self.cur[ra].node;
    }
    if (self.cur[rc].node != NO_NODE) value = self.cur[rc].node;
    uint n = self.add(OptOp.INIT_SLOT, OptRep.NONE, value, obj, (long)self.pc);
    self.snapshot(n);
    // A slot named by index, of whatever key.
    self.avail_n = 0;
    return true;
}

// Register `r` no longer holds a numeric node.
fn void OptBuild.kill(&self, uint r) {
    if (r >= self.nregs) return;
    self.cur[r] = { .node = NO_NODE, .dirty = false };
    self.load_def[r] = NO_NODE;
    self.const_def[r] = NO_NODE;
    self.fact_shape[r] = heap::SHAPE_NONE;
    self.fact_elem[r] = 0;
    self.drop_reg(r, NO_NODE);
}

// Whether the call the tier runs as a GENERIC enters its callee directly, guarded here by
// CHECK_CALLEE: the functions its feedback names, each with a call entry whose shape tests the
// call passes (entry_takes). `one` gets the function when it is the only one (entered through its
// direct label, Asm.emit_direct_call, or its register label), else null: a polymorphic call, which
// only a register call makes (CALL_REG of the function the callee holds). A call of a variable
// reads it for the guard first, as an inlined one does.
fn bool OptBuild.direct_callee(&self, CompiledFunction** one) {
    Opcode op = self.w.op;
    bool var_call = op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL;
    if ((op != Opcode.CALL && op != Opcode.CALL_UNDEF_THIS && !var_call) || self.wide || self.f.ic_entries == null) return false;
    if (var_call && self.f.var_ic_entries == null) return false;
    uint at = self.next_pc - 1;
    OptCallees set;
    if (opt_site_banned(self.f, self.f, at) || !opt_direct_targets(self.h, self.f, at, &set)) return false;
    bool method = op == Opcode.CALL;
    CompiledFunction* cf = set.count == 1 ? set.fns[0] : null;
    uint callee_reg = var_call ? self.w.a : self.w.b;
    uint callee_node = NO_NODE;
    uint recv_node = NO_NODE;
    if (var_call) {
        uint closure;
        if (!self.body_closure(&closure)) return false;
        // Into a VALUE node beyond the caller's frame, else into the callee register.
        bool beyond = callee_reg >= self.caller_regs;
        uint load = self.add(OptOp.LOAD_VAR, beyond ? OptRep.VALUE : OptRep.NONE, NO_NODE, closure, (long)self.pc);
        self.g.nodes[load].cc = op == Opcode.CALL_VAR ? 1 : 0;
        self.snapshot(load);
        if (beyond) {
            self.set(callee_reg, load);
            callee_node = load;
        } else {
            self.kill(callee_reg);
        }
    } else {
        if (!self.call_operand(callee_reg, &callee_node)) return false;
        if ((method || callee_reg + 1 < self.caller_regs) && !self.call_operand(callee_reg + 1, &recv_node)) return false;
    }
    uint chk = self.add(OptOp.CHECK_CALLEE, OptRep.NONE, callee_node, recv_node, (long)(usz)cf);
    self.g.nodes[chk].cc = method ? 1 : 0;
    if (cf == null) {
        self.g.callees.push(set);
        self.g.nodes[chk].poly = (uint)self.g.callees.len();
    } else if (method) {
        self.settle_method(chk, callee_reg, cf);
    }
    // A variable's binding as it stands, which the guard then compares the read with.
    if (var_call && cf != null) {
        hobject::VarICEntry* vic = &((hobject::VarICEntry*)self.f.var_ic_entries)[at];
        if (vic.slot_ptr != null && vic.recycle_epoch == self.h.shape_recycle_epoch) {
            self.g.nodes[chk].key = constant_callee(vic.slot_ptr.get(), cf);
        }
    }
    self.snapshot(chk);
    self.direct_calls++;
    *one = cf;
    return true;
}

// The call being lowered, of the callee `cf` its guard proved (direct_callee; null for any of a
// polymorphic call's), as a CALL_REG into the register label of the callee's code as it stands:
// its window stored, and what a call leaves, its window dead, its result in the window and
// nothing known of the heap, but the caller's values kept in their registers.
fn bool OptBuild.reg_call(&self, CompiledFunction* cf) {
    bool var_call = self.w.op == Opcode.CALL_VAR || self.w.op == Opcode.CALL_GLOBAL;
    uint callee_reg = var_call ? self.w.a : self.w.b;
    uint n = self.add(OptOp.CALL_REG, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
    self.g.nodes[n].key = cf;
    self.forget_facts();
    self.snapshot(n);
    OptNode* node = &self.g.nodes[n];
    for (uint k = 0; k < node.dirty_count; k++) self.cur[self.g.dirty[(sz)(node.dirty_first + k)].reg].dirty = false;
    for (uint r = callee_reg; r < self.nregs; r++) self.kill(r);
    self.kill(self.w.a);
    return true;
}

// The instruction as the baseline emitter runs it: the registers it can read
// stored first, the registers it can write no longer numeric nodes, and the
// numeric registers live after it reloaded from the window.
fn bool OptBuild.generic(&self) {
    // An inlined body holds nothing that runs as a GENERIC: the site stays a call.
    if (self.cur_fn != 0) {
        self.inline_failed = true;
        return true;
    }
    // Which registers the instruction writes: only the opcodes whose effect on
    // the register file is known run as GENERIC.
    uint first_kill = NO_NODE;   // calls: this register and every one above it
    uint extra_kill = NO_NODE;
    uint key_kill = NO_NODE;     // GETPROP_CACHE writes the coerced key back to C
    uint def = NO_NODE;
    Opcode op = self.w.op;
    if (!self.cur_cfg().nodes[self.insn].must_def(&def)) {
        def = NO_NODE;
        switch (op) {
            // The compiler's own cells: NEWCELLS builds one, GETCELL writes A, and MOVECELL clears
            // the A it moved into the cell (its roles read A and leave the write out).
            case NEWOBJ: case NEWARR: case NEWARR_CONST: case CLOSURE: case NEWREGEXP:
            case NEWOBJ_SHAPE: case NEWTARGET: case DELPROP: case GETPROP_SUPER: case TOPROPKEY: case RESOLVEVAR:
            case NEWCELLS: case GETCELL: case MOVECELL:
                extra_kill = self.w.a;
            case GETPROP_CACHE:
                extra_kill = self.w.a;
                key_kill = self.w.c;
            case CALL: case CALL_PROP: case CALL_UNDEF_THIS: case NEW_OBJ: case CALL_S: case NEW_OBJ_S:
                extra_kill = self.w.a;
                first_kill = self.w.b;
            case CALL_VAR: case CALL_GLOBAL:
                first_kill = self.w.a;
            case PUTPROP: case PUTPROP_NE: case PUTPROPC: case PUTTHISC: case PUTVAR: case PUTVAR_ASSIGN:
            case PUTVAR_SNAP: case PUTGLOBAL: case PUTCAP: case PUTCAP_SNAP: case PUTLEX: case PUTLEX_C:
            case RET: case RETUNDEF: case SETALEN: case INITPROP: case INITELEM: case CHKOBJ: case REQUIRE_OBJ:
            case NOP: case INC_VAR: case DEC_VAR: case INC_GLOBAL: case DEC_GLOBAL: case CHKGLOBALVAR:
            case CHKGLOBALFUNC: case CHKGLOBALLEX: case THROW: case THROW_UNRESOLVED:
            case SETCELL:
                break;
            default:
                return self.refuse_op(op);
        }
    }
    CompiledFunction* direct;
    bool guarded = self.direct_callee(&direct);
    if (guarded && REG_CALLS) return self.reg_call(direct);
    if (!guarded) direct = null;
    uint n = self.add(OptOp.GENERIC, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
    self.g.nodes[n].key = direct;
    self.forget_facts();
    self.snapshot(n);
    OptNode* node = &self.g.nodes[n];
    for (uint i = 0; i < node.dirty_count; i++) {
        self.cur[self.g.dirty[(sz)(node.dirty_first + i)].reg].dirty = false;
    }
    self.kill(extra_kill);
    self.kill(key_kill);
    if (first_kill < self.nregs) for (uint r = first_kill; r < self.nregs; r++) self.kill(r);
    self.kill(def);
    uint first = (uint)self.g.dirty.len();
    for (uint r = 0; r < self.nregs; r++) {
        if (self.cur[r].node != NO_NODE && self.live_out_at(r)) {
            self.g.dirty.push({ .reg = r, .node = self.cur[r].node });
        }
    }
    node = &self.g.nodes[n];
    node.reload_first = first;
    node.reload_count = (uint)self.g.dirty.len() - first;
    return true;
}

fn bool OptBuild.terminator(&self, OptOp op, uint a = NO_NODE, uint b = NO_NODE, long imm = 0, char cc = 0) {
    uint n = self.add(op, OptRep.NONE, a, b, imm);
    self.g.nodes[n].cc = cc;
    return true;
}

// A compare-and-branch.
fn bool OptBuild.cmp_branch(&self) {
    Opcode op = self.w.op;
    bool imm = is_jmp_imm(op);
    if (imm && self.wide) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    uint row = imm ? op.ordinal - Opcode.JMP_NLTI.ordinal : op.ordinal - Opcode.JMP_NLT.ordinal;
    OptRep rep = self.arith_rep(self.w.b, imm ? NO_NODE : self.w.c);
    if (rep == OptRep.NONE) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    uint x = self.operand(self.w.b, rep);
    uint y = imm ? self.imm_operand((long)(ichar)self.w.c, rep) : self.operand(self.w.c, rep);
    if (x == NO_NODE || y == NO_NODE) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    return self.terminator(OptOp.BRANCH, x, y, (long)rep.ordinal, (char)row);
}

// IF_TRUE / IF_FALSE over a number or boolean node or the window slot.
fn bool OptBuild.truth_branch(&self) {
    uint r = self.w.a;
    if (r >= self.nregs) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    uint node = self.truth_operand(r);
    bool negate = self.w.op == Opcode.IF_FALSE;
    if (!self.terminator(OptOp.BRANCH_TRUTH, node, NO_NODE, (long)r, negate ? 1 : 0)) return false;
    // A window value can leave through the slow path.
    if (node == NO_NODE) self.snapshot((uint)self.g.nodes.len() - 1);
    return true;
}

// JMP_SEQ/SNEQ/EQ/NEQ/NULL/NNULL: values in the window go through the baseline's tests; once
// either operand is a numeric node the operands compare as numbers.
fn bool OptBuild.equality_branch(&self) {
    Opcode op = self.w.op;
    bool unary = op == Opcode.JMP_NULL || op == Opcode.JMP_NNULL;
    uint rb = self.w.b;
    uint rc = unary ? rb : self.w.c;
    if (rb >= self.nregs || rc >= self.nregs) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    bool numeric_b = self.cur[rb].node != NO_NODE && !self.holds_value(rb);
    bool numeric_c = self.cur[rc].node != NO_NODE && !self.holds_value(rc);
    if (numeric_b || numeric_c) {
        if (self.holds_value(rb)) self.publish_value(rb);
        if (self.holds_value(rc)) self.publish_value(rc);
        return unary ? self.refuse_op(op) : self.numeric_equality();
    }
    uint kind = op.ordinal - Opcode.JMP_SEQ.ordinal;
    long imm = (long)rb | ((long)rc << 20);
    uint other = NO_NODE;
    char cc = unary ? (char)kind : self.equality_cc(kind, rb, rc, &imm, &other);
    // Against a constant, the other slot is tested alone.
    if (other != NO_NODE) {
        rb = other;
        rc = other;
        unary = true;
    }
    // A VALUE operand is tested in its register, which a read into the window becomes in the next
    // round; one a read left in a slot beyond the caller's frame waits for it.
    if (self.cur[rb].node == NO_NODE) self.ask_value(rb);
    if (self.cur[rc].node == NO_NODE) self.ask_value(rc);
    uint xb = self.holds_value(rb) ? self.cur[rb].node : NO_NODE;
    uint xc = self.holds_value(rc) ? self.cur[rc].node : NO_NODE;
    if (self.cur_fn != 0) {
        if (xb == NO_NODE && rb >= self.caller_regs) self.call_operand(rb, &xb);
        if (xc == NO_NODE && rc >= self.caller_regs) self.call_operand(rc, &xc);
    }
    if (!self.terminator(OptOp.BRANCH_WINDOW, xb, unary ? NO_NODE : xc, imm, cc)) return false;
    self.snapshot((uint)self.g.nodes.len() - 1);
    return true;
}

// Loose or strict equality of two numeric nodes: the same compare as the strict branch.
fn bool OptBuild.numeric_equality(&self) {
    Opcode op = self.w.op;
    uint row = (op == Opcode.JMP_SEQ || op == Opcode.JMP_EQ) ? 8 : 9;
    OptRep rep = self.arith_rep(self.w.b, self.w.c);
    if (rep == OptRep.NONE) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    uint x = self.operand(self.w.b, rep);
    uint y = self.operand(self.w.c, rep);
    if (x == NO_NODE || y == NO_NODE) return self.refuse(OptRefuse.BRANCH_OPERANDS);
    return self.terminator(OptOp.BRANCH, x, y, (long)rep.ordinal, (char)row);
}

// --- Inlining ---
//
// A CALL or CALL_UNDEF_THIS whose feedback names one callee, a lean function with a short straight-line
// body of field reads, numeric arithmetic and a return, is replaced by that body, built into the
// caller's block with the callee's registers at base + r (the window the call would publish). A
// CHECK_CALLEE node before it leaves for the baseline code, at the call, unless the callee is that
// function and the call could be published; an exit from inside the body publishes the callee's frame
// first (opt_inline_exit) and continues in the callee's baseline code.

// Set the lowering context to instruction `k` of an inline site's callee.
fn void OptBuild.inline_context(&self, OptInlineSite* s, uint k) {
    DecodedCfgNode* node = &s.cfg.nodes[k];
    self.insn = k;
    self.pc = node.view.pc;
    self.next_pc = node.view.next_pc;
    self.w = node.view.insn;
    self.wide = false;
    inline_rebase(&self.w, s.base);
    if (k == s.remap) self.w.a = self.g.fns[self.cur_fn].remap_reg;
}

// Whether every instruction of the callee of `s` is one the builder lowers without a GENERIC (given
// what the callee's caches and feedback say), so that nothing in the body can call, allocate or throw.
// The graph registers of the callee's window must lie in the caller's own register file when anything
// but a number is written to them (OptBuild.inline_unsafe); that is decided while building.
fn bool OptBuild.inline_body_ok(&self, OptInlineSite* s, uint nargs) {
    CompiledFunction* cf = s.cf;
    DecodedCfg* cfg = &s.cfg;
    if (cfg.has_wide || cfg.instruction_count == 0) return self.reject(OptInlineReject.WIDE);
    // The first opcode outside the whitelist is the better reason for a body that also branches.
    s.has_calls = false;
    for (uint k = 0; k < cfg.instruction_count; k++) {
        Opcode op = cfg.nodes[k].view.insn.op;
        if (!inline_op_ok(op)) { self.rej_op = op; return self.reject(OptInlineReject.OPCODE); }
        s.has_calls |= inline_call_op(op) && !opt_push_site(self.h, cf, cfg.nodes[k].view.pc);
        // A CALL_S is a spread call unless it completes a forwarding call, which only a function
        // whose `arguments` register holds the argument count makes.
        bool paired = op == Opcode.APPLY_ARGS ? forward_pair(cfg, k) : (op != Opcode.CALL_S || (k > 0 && forward_pair(cfg, k - 1)));
        if (!paired || (op == Opcode.APPLY_ARGS && !cf.call_flags.forward_args)) {
            self.rej_op = op;
            return self.reject(OptInlineReject.OPCODE);
        }
    }
    // Forward branches only: a loop in the callee stays a call.
    if (cfg.has_backedge) return self.reject(OptInlineReject.BLOCKS);
    s.flat = cfg.block_count != 1;
    if (s.flat && s.dotcall) return self.reject(OptInlineReject.DOTCALL_FLAT);
    if (s.flat && !self.splice_ok(s)) return false;
    // Calls nest as deep as OPT_INLINE_DEPTH.
    if (s.has_calls && s.depth >= OPT_INLINE_DEPTH) {
        self.rej_op = Opcode.CALL;
        for (uint k = 0; k < cfg.instruction_count; k++) {
            if (cfg.nodes[k].view.insn.op == Opcode.NEW_OBJ) self.rej_op = Opcode.NEW_OBJ;
        }
        return self.reject(OptInlineReject.DEPTH);
    }
    Opcode last_op = cfg.nodes[cfg.instruction_count - 1].view.insn.op;
    if (last_op != Opcode.RET && last_op != Opcode.RETUNDEF) return self.reject(OptInlineReject.NO_RET);
    // Nothing but the arguments may be read before it is written: the window slots are not cleared.
    // Missing formals are stored undefined (OptBuild.enter_args); surplus arguments stay, as a
    // frame's do.
    s.defined = mem::new_array(uint, cfg.instruction_count);
    uint given = max(nargs, cf.num_formals);
    uint argmask = given >= 32 ? ~0u : (1u << given) - 1;
    s.remap = uint::max;
    if (s.flat) {
        // A forward dataflow: what every path to an instruction has written.
        bool* reached = mem::new_array(bool, cfg.instruction_count);
        defer mem::free(reached);
        s.defined[0] = argmask;
        reached[0] = true;
        for (uint k = 0; k < cfg.instruction_count; k++) {
            if (!reached[k]) continue;
            DecodedCfgNode* node = &cfg.nodes[k];
            uint reads;
            uint writes;
            inline_rw(&node.view.insn, &reads, &writes);
            if ((reads & ~s.defined[k]) != 0) return self.reject(OptInlineReject.READ_UNDEF);
            uint out = s.defined[k] | writes;
            for (uint e = 0; e < node.successor_count; e++) {
                uint t = node.successors[e];
                if (t <= k) return self.reject(OptInlineReject.BLOCKS);
                s.defined[t] = reached[t] ? (s.defined[t] & out) : out;
                reached[t] = true;
            }
            if (node.successor_count == 0 && node.view.insn.op != Opcode.RET && node.view.insn.op != Opcode.RETUNDEF && node.view.insn.op != Opcode.THROW) return self.reject(OptInlineReject.NO_RET);
        }
    } else {
        uint defined = argmask;
        for (uint k = 0; k < cfg.instruction_count; k++) {
            DecodedInsn w = cfg.nodes[k].view.insn;
            uint reads;
            uint writes;
            inline_rw(&w, &reads, &writes);
            if ((reads & ~defined) != 0) return self.reject(OptInlineReject.READ_UNDEF);
            s.defined[k] = defined;
            defined |= writes;
        }
        if (cfg.instruction_count >= 2 && last_op == Opcode.RET && !s.construct) {
            uint last = cfg.instruction_count - 2;
            uint rr = cfg.nodes[last + 1].view.insn.a;
            uint reads;
            uint writes;
            DecodedInsn lw = cfg.nodes[last].view.insn;
            inline_rw(&lw, &reads, &writes);
            // A call's result register is also its callee register, which the call guard reads.
            bool alone = writes == (1u << rr) && !inline_call_op(lw.op) && lw.op != Opcode.CALL_S;
            for (uint k = 0; k < last && alone; k++) {
                DecodedInsn kw = cfg.nodes[k].view.insn;
                uint r2;
                uint w2;
                inline_rw(&kw, &r2, &w2);
                if (((r2 | w2) & (1u << rr)) != 0) alone = false;
            }
            if (alone) s.remap = last;
        }
    }
    uint saved_fn = self.cur_fn;
    uint saved_site = self.cur_site;
    self.g.fns.push({ .f = cf, .reg_base = s.base, .remap_pc = uint::max });
    self.cur_fn = (uint)self.g.fns.len() - 1;
    self.cur_site = 0;
    bool ok = true;
    OptInlineReject why = OptInlineReject.FEEDBACK;
    for (uint k = 0; k < cfg.instruction_count && ok; k++) {
        self.inline_context(s, k);
        Opcode op = self.w.op;
        if (opt_site_banned(self.f, cf, self.next_pc - 1)) {
            ok = false;
            why = OptInlineReject.BANNED;
            break;
        }
        switch (op) {
            case ADD: case ADD_FUSED: case SUB: case MUL: case DIV: case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR:
            case ADDI: case SUBI: case MULI: case BANDI: case BORI: case BXORI: case SHLI: case SHRI: case USHRI:
            case INC: case DEC: case INC_LT: case UNM: case BNOT: case LT: case LE: case GT: case GE:
            case JMP_NLT..JMP_GE: case JMP_NLTI..JMP_SNEQI:
                ok = (self.feedback() & (hobject::FB_STR | hobject::FB_OTHER)) == 0;
            case MOD:
                // An exit at every negative dividend or non-positive divisor would not pay.
                ok = (self.feedback() & hobject::FB_OPERANDS) == 0;
            case GETPROPC: case GETPROPC_CACHED:
                ok = self.length_site() || self.own_field(true) != null || (s.flat && self.cold_field());
                why = OptInlineReject.FIELD;
            case GETTHISC:
                ok = ((s.method || s.construct) && self.own_field(true) != null) || (s.flat && self.cold_field());
                why = OptInlineReject.FIELD;
            case PUTPROPC:
                hobject::ICEntry* ic = self.own_field();
                ok = (ic != null && ic.prop_flags.writable) || (s.flat && self.cold_field());
                why = OptInlineReject.FIELD;
            case PUTTHISC:
                hobject::ICEntry* ic = self.own_field();
                ok = (s.method && ic != null && ic.prop_flags.writable) || (s.flat && self.cold_field())
                    || ((s.construct || s.forward || s.dotcall) && ((ic != null && ic.prop_flags.writable) || self.absent_field() != null));
                why = OptInlineReject.FIELD;
            case GETGLOBAL: case GETVAR:
                ok = (s.flat && self.cold_field()) || ((hobject::VarICEntry*)cf.var_ic_entries)[self.next_pc - 1].env != null;
                why = OptInlineReject.GLOBAL;
            case LDTHIS:
                ok = s.method || s.construct;
                why = OptInlineReject.THIS;
            case LDCONST:
                uint index = self.w.get_bc();
                ok = index < cf.const_count && (cf.constants[index].is_fastint() || cf.constants[index].is_number());
                why = OptInlineReject.CONSTANT;
            default:
                break;
        }
    }
    if (!ok) self.reject(why);
    self.g.fns.size = self.g.fns.len() - 1;
    self.cur_fn = saved_fn;
    self.cur_site = saved_site;
    return ok;
}

// Whether the body of site `s` can be spliced into the graph (OptBuild.flatten). A constructor's
// returns become the copy of its object, which a return of a value would have to be proven not to
// replace. A forwarding body's arguments are kept live up to its forwarding call (forward_liveness)
// over its own instructions, which therefore must run in a straight line, no other spliced body among
// them.
fn bool OptBuild.splice_ok(&self, OptInlineSite* s) {
    DecodedCfg* cfg = &s.cfg;
    for (uint k = 0; k < cfg.instruction_count; k++) {
        if (s.construct && cfg.nodes[k].view.insn.op == Opcode.RET) return self.reject(OptInlineReject.CTOR_BODY);
    }
    if (!s.cf.arguments_in_reg()) return true;
    if (cfg.block_count != 1) return self.reject(OptInlineReject.SPLICE);
    if (s.child_of == null) return true;
    for (uint k = 0; k < cfg.instruction_count; k++) {
        uint c = s.child_of[k];
        if (c != 0 && self.sites[(sz)c - 1].flat && !self.sites[(sz)c - 1].forward) return self.reject(OptInlineReject.SPLICE);
    }
    return true;
}

// Whether the call at instruction `i` is an inline site, filling `s` when it is. The call is the
// function's own for `parent` zero, else one of the body of inline site `parent - 1`, whose window
// the new site's nests in.
fn bool OptBuild.inline_candidate(&self, uint i, OptInlineSite* s, uint parent = 0, CompiledFunction* want = null) {
    OptInlineSite* ps = parent == 0 ? null : &self.sites[(sz)parent - 1];
    DecodedBytecode view = ps == null ? self.cfg.nodes[i].view : ps.cfg.nodes[i].view;
    Opcode op = view.insn.op;
    CompiledFunction* f = ps == null ? self.f : ps.cf;
    // The caller's registers: the frame of the function being optimized, or the parent's window.
    uint regs = ps == null ? self.caller_regs : f.num_regs;
    RegSet* live_out = ps == null ? &self.live_out[i] : &ps.live_out[i];
    uint depth = ps == null ? 1 : ps.depth + 1;
    bool var_call = op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL;
    bool construct = op == Opcode.NEW_OBJ;
    bool forward = op == Opcode.APPLY_ARGS;
    if ((op != Opcode.CALL && op != Opcode.CALL_UNDEF_THIS && !var_call && !construct && !forward) || view.wide || f.ic_entries == null) return false;
    if (var_call && f.var_ic_entries == null) return false;
    // A forwarding call passes on the arguments of the inlined body it is in, whose count is its
    // site's (inline_body_ok checked the pair and that `arguments` holds that count).
    if (forward && (ps == null || !forward_pair(&ps.cfg, i))) return false;
    if (forward) live_out = &ps.live_out[i + 1];
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[view.next_pc - 1];
    if ((ic.feedback & (construct ? hobject::FB_CTOR : hobject::FB_CALL)) == 0) return false;
    self.rej_caller = f;
    self.rej_pc = view.pc;
    self.rej_callee = null;
    CompiledFunction* cf;
    // A forwarding function shared by many callers forwards to many functions: the call that
    // reached it, the site's parent, records the function it forwarded to from there.
    hobject::ICEntry* outer = forward ? self.site_ic(ps) : null;
    if (want != null) {
        // One of the callees of a polymorphic call (OptBuild.poly_sites).
        if (opt_site_banned(self.f, f, view.next_pc - 1)) return self.reject(OptInlineReject.POLY);
        cf = want;
    } else if (outer != null && outer.fwd_callee != 0) {
        if ((outer.feedback & hobject::FB_FWD_POLY) != 0) return self.reject(OptInlineReject.POLY);
        if (outer.fwd_callee > self.h.compiled_func_count) return false;
        cf = (CompiledFunction*)self.h.compiled_funcs[outer.fwd_callee - 1];
    } else {
        if ((ic.feedback & hobject::FB_POLY) != 0 || (!construct && hobject::ic_call_count(ic) != 1) || opt_site_banned(self.f, f, view.next_pc - 1)) return self.reject(OptInlineReject.POLY);
        cf = opt_site_callee(self.h, f, view.next_pc - 1);
    }
    uint callee_reg = var_call ? view.insn.a : view.insn.b;
    uint nargs = forward ? ps.nargs : (var_call ? view.insn.b : view.insn.c);
    // `X.call(x, args)`: the site's own window (callee register, X, x, args) holds one argument more
    // than X's.
    bool dotcall = op == Opcode.CALL && (ic.feedback & hobject::FB_DOTCALL) != 0;
    if (dotcall && nargs == 0) return false;
    bool method = op == Opcode.CALL || forward;
    // The window the call publishes lies in the caller's registers as far as the arguments go.
    if (cf == null) return false;
    self.rej_callee = cf;
    if (construct && !opt_base_constructor(cf)) return self.reject(OptInlineReject.CTOR);
    if (cf == f || cf == self.f) return self.reject(OptInlineReject.SELF);
    for (OptInlineSite* a = ps; a != null; a = a.parent == 0 ? null : &self.sites[(sz)a.parent - 1]) {
        if (a.cf == cf) return self.reject(OptInlineReject.SELF);
    }
    if (depth > OPT_INLINE_DEPTH) return self.reject(OptInlineReject.DEPTH);
    // (A forwarding call's arguments are moved into its window from the body's first registers.)
    if (!forward && callee_reg + 2 + nargs > regs) return self.reject(OptInlineReject.WINDOW);
    if (dotcall) nargs--;
    cf.classify_lean_call();
    if (cf.realm != f.realm || !opt_function_eligible(cf, true)) return self.reject(OptInlineReject.INELIGIBLE);
    if (!cf.call_flags.lean_call || (!method && !construct && !cf.call_flags.lean_plain)) return self.reject(OptInlineReject.NOT_LEAN);
    // A callee may read `arguments` only to forward it: then the register holds the count of the
    // arguments, which stay in its first registers (CallFlags.forward_args).
    bool counted_args = cf.call_flags.forward_args && nargs <= (uint)cf.num_args + bytecode::FORWARD_ARGS_PAD;
    if ((cf.arguments_in_reg() && !counted_args) || cf.call_flags.rest_length_only || cf.ic_entries == null || cf.var_ic_entries == null) return self.reject(OptInlineReject.ARGS);
    if (is_top_level(cf)) return self.reject(OptInlineReject.TOP_LEVEL);
    if (cf.num_regs > 32 || cf.code_count > INLINE_WORDS_MAX) return self.reject(OptInlineReject.SIZE);
    // What a call leaves behind is its result: the rest of its window is dead after it.
    // (A call that names no receiver leaves `this` implicit, which liveness takes for live around a loop;
    // a NEW_OBJ writes its object there.)
    for (uint r = callee_reg; r < regs; r++) {
        if (r == view.insn.a || (!method && !construct && r == callee_reg + 1)) continue;
        if (live_out.test(r)) return self.reject(OptInlineReject.WINDOW_LIVE);
    }
    uint base = (ps == null ? 0 : ps.base) + callee_reg + 2;
    *s = { .insn = i, .cf = cf, .base = base, .method = method, .construct = construct, .var_call = var_call, .forward = forward, .dotcall = dotcall,
           .nargs = nargs, .parent = parent, .depth = depth };
    bool ok = compiler::bytecode_cfg_build(&s.cfg, cf.code, cf.code_count, self.h, forwarding: true);
    if (ok) {
        uint count = s.cfg.instruction_count;
        uint words = (cf.num_regs + 32) / 32;
        s.live_sets = mem::new_array(RegSet, (usz)count * 2);
        s.live_words = mem::new_array(uint, ((usz)count * 2 + 1) * words);
        for (uint k = 0; k < count * 2; k++) s.live_sets[k] = { .words = s.live_words + (usz)k * words, .word_count = words };
        RegSet scratch = { .words = s.live_words + (usz)count * 2 * words, .word_count = words };
        compiler::bytecode_cfg_liveness(&s.cfg, s.live_sets, s.live_sets + count, &scratch, true, false, true);
        s.live_out = s.live_sets;
        s.live_in = s.live_sets + count;
        if (cf.arguments_in_reg()) s.forward_liveness();
        ok = self.inline_body_ok(s, nargs);
    }
    // An exit from the body continues in the callee's baseline code: compile it now if it has none.
    if (ok && cf.jit_code == null) {
        ok = !cf.jit_refused && baseline_try_compile(self.h, cf, false) != null;
        if (!ok) self.reject(cf.call_flags.trivial_call != 0 ? OptInlineReject.NO_JIT_TRIVIAL : OptInlineReject.NO_JIT);
    }
    if (!ok) s.free_site();
    return ok;
}

// The cache entry of the call instruction of site `s` in its caller's code.
fn hobject::ICEntry* OptBuild.site_ic(&self, OptInlineSite* s) {
    OptInlineSite* ps = s.parent == 0 ? null : &self.sites[(sz)s.parent - 1];
    CompiledFunction* f = ps == null ? self.f : ps.cf;
    DecodedBytecode view = ps == null ? self.cfg.nodes[s.insn].view : ps.cfg.nodes[s.insn].view;
    if (f.ic_entries == null) return null;
    return &((hobject::ICEntry*)f.ic_entries)[view.next_pc - 1];
}

// What a forwarding call (APPLY_ARGS) reads, which liveness does not see: the arguments, which stay
// in the body's first registers, and the registers of the call. They are taken for live from the
// entry (the body is straight-line), so that an exit before the call publishes them.
fn void OptInlineSite.forward_liveness(&self) {
    uint n = min(self.nargs, self.cf.num_regs);
    for (uint j = 0; j < self.cfg.instruction_count; j++) {
        DecodedInsn w = self.cfg.nodes[j].view.insn;
        if (w.op != Opcode.APPLY_ARGS) continue;
        for (uint k = 0; k <= j; k++) {
            for (uint r = 0; r < n; r++) self.live_in[k].set(r);
            for (uint r = w.a; r <= w.a + 2 && r < self.cf.num_regs; r++) self.live_in[k].set(r);
            self.live_in[k].set(w.c);
        }
        for (uint k = 0; k < j; k++) self.live_out[k].union_with(&self.live_in[k + 1]);
    }
}

// Find the inline sites, and widen nregs to hold their callee windows.
fn void OptBuild.find_sites(&self) {
    if (self.no_inline || self.h.opt.no_inline) return;
    uint count = self.cfg.instruction_count;
    uint flat_total = 0;
    for (uint i = 0; i < count; i++) {
        if (self.poly_sites(i, &flat_total)) continue;
        OptInlineSite s;
        self.rej = OptInlineReject.BUILD;
        if (!self.inline_candidate(i, &s)) {
            Opcode cop = self.cfg.nodes[i].view.insn.op;
            bool is_call = inline_call_op(cop);
            if (is_call && self.rej != OptInlineReject.BUILD) self.count_reject(self.rej, self.rej_op);
            continue;
        }
        if (self.site_of == null) self.site_of = mem::new_array(uint, count);
        uint si = (uint)self.sites.len();
        uint nregs0 = self.nregs;
        self.sites.push(s);
        self.site_of[i] = si + 1;
        uint need = s.base + s.cf.num_regs;
        if (need > self.nregs) self.nregs = need;
        uint words = s.cf.code_count;
        if (!self.add_children(si, &words)) {
            // A call in the body that cannot be inlined in turn leaves this one a call too.
            for (sz j = self.sites.len(); j > si; j--) self.sites[j - 1].free_site();
            self.sites.size = si;
            self.site_of[i] = 0;
            self.nregs = nregs0;
            self.count_reject(OptInlineReject.OPCODE, self.rej_op == Opcode.NEW_OBJ ? Opcode.NEW_OBJ : Opcode.CALL);
            continue;
        }
        // A tree holding a branching body is spliced into the graph from its root down to every
        // such body; the rest of it is lowered in place, in the spliced bodies.
        uint end = (uint)self.sites.len();
        bool spliced = false;
        for (uint j = end; j > si; j--) {
            OptInlineSite* t = &self.sites[(sz)j - 1];
            if (!t.flat) continue;
            spliced = true;
            if (t.parent != 0) self.sites[(sz)t.parent - 1].flat = true;
        }
        if (!spliced) continue;
        // The splice needs the instruction after the call as the join, a room in the graph,
        // and the tree not to have failed an earlier build.
        bool ok = true;
        uint size = 0;
        for (uint j = si; j < end && ok; j++) {
            OptInlineSite* t = &self.sites[j];
            if (!t.flat) continue;
            ok = self.splice_ok(t);
            t.remap = uint::max;
            t.head_pc = self.cfg.nodes[i].view.pc;
            size += t.cfg.instruction_count;
        }
        bool skip = !ok || i + 1 >= count || flat_total + size + count > compiler::DEFAULT_CFG_BUDGET.max_instructions;
        for (uint e = 0; e < self.exclude_count; e++) skip = skip || self.exclude[e] == self.cfg.nodes[i].view.pc;
        if (!skip && self.h.opt.inline_seen >= self.h.opt.inline_max) skip = true;
        if (skip) {
            for (sz j = self.sites.len(); j > si; j--) self.sites[j - 1].free_site();
            self.sites.size = si;
            self.site_of[i] = 0;
            self.nregs = nregs0;
            if (!ok) self.count_reject(self.rej, Opcode.NOP);
            continue;
        }
        self.h.opt.inline_seen++;
        flat_total += size;
        self.flat_count++;
    }
    // The rejections counted while building name no site of their own.
    self.rej_caller = null;
}

// The most callees of one polymorphic call whose bodies the graph inlines, and the bytecode words
// of all of their trees together.
const uint POLY_WORDS_MAX = 240;

// Whether the call at instruction `i` of the function being optimized is a polymorphic one whose
// feedback names two to four callees (hobject::ic_call_count), of which at least one is inlined:
// then each such callee is a flat site of its own (OptInlineSite.poly, linked by poly_next from
// site_of[i]), spliced after a test of the callee, and a callee that none names takes the call
// itself (OptBuild.flatten), as JSC's DFG switches on the callee.
fn bool OptBuild.poly_sites(&self, uint i, uint* flat_total) {
    DecodedBytecode view = self.cfg.nodes[i].view;
    Opcode op = view.insn.op;
    if ((op != Opcode.CALL && op != Opcode.CALL_UNDEF_THIS) || view.wide || self.f.ic_entries == null) return false;
    hobject::ICEntry* ic = &((hobject::ICEntry*)self.f.ic_entries)[view.next_pc - 1];
    if ((ic.feedback & hobject::FB_DOTCALL) != 0) return false;
    uint n = hobject::ic_call_count(ic);
    if (n < 2 || opt_site_banned(self.f, self.f, view.next_pc - 1)) return false;
    for (uint e = 0; e < self.exclude_count; e++) if (self.exclude[e] == view.pc) return false;
    if (self.h.opt.inline_seen >= self.h.opt.inline_max) return false;
    if (self.site_of == null) self.site_of = mem::new_array(uint, self.cfg.instruction_count);
    uint prev = 0;
    uint size = 0;
    uint words_all = 0;
    uint nregs0 = self.nregs;
    sz first = self.sites.len();
    for (uint k = 0; k < n; k++) {
        uint index = hobject::ic_call_target(ic, k);
        if (index >= self.h.compiled_func_count || self.h.compiled_funcs[index] == null) continue;
        CompiledFunction* cf = (CompiledFunction*)self.h.compiled_funcs[index];
        OptInlineSite s;
        self.rej = OptInlineReject.BUILD;
        if (!self.inline_candidate(i, &s, 0, cf)) {
            if (self.rej != OptInlineReject.BUILD) self.count_reject(self.rej, self.rej_op);
            continue;
        }
        uint si = (uint)self.sites.len();
        uint nregs_k = self.nregs;
        self.sites.push(s);
        uint need = s.base + s.cf.num_regs;
        if (need > self.nregs) self.nregs = need;
        uint words = s.cf.code_count;
        bool ok = self.add_children(si, &words) && words_all + words <= POLY_WORDS_MAX;
        uint end = (uint)self.sites.len();
        if (ok) {
            self.sites[si].flat = true;
            for (uint j = end; j > si + 1; j--) {
                OptInlineSite* t = &self.sites[(sz)j - 1];
                if (t.flat && t.parent != 0) self.sites[(sz)t.parent - 1].flat = true;
            }
        }
        uint tree = 0;
        for (uint j = si; j < end && ok; j++) {
            OptInlineSite* t = &self.sites[j];
            if (!t.flat) continue;
            ok = self.splice_ok(t);
            t.remap = uint::max;
            t.head_pc = view.pc;
            tree += t.cfg.instruction_count;
        }
        if (!ok) {
            if (self.rej == OptInlineReject.BUILD) self.count_reject(OptInlineReject.OPCODE, Opcode.CALL);
            for (sz j = self.sites.len(); j > si; j--) self.sites[j - 1].free_site();
            self.sites.size = si;
            self.nregs = nregs_k;
            continue;
        }
        words_all += words;
        size += tree + 2;
        self.sites[si].poly = true;
        if (prev == 0) {
            self.site_of[i] = si + 1;
        } else {
            self.sites[(sz)prev - 1].poly_next = si + 1;
        }
        prev = si + 1;
    }
    if (prev == 0) return false;
    if (*flat_total + size + self.cfg.instruction_count > compiler::DEFAULT_CFG_BUDGET.max_instructions) {
        for (sz j = self.sites.len(); j > first; j--) self.sites[j - 1].free_site();
        self.sites.size = first;
        self.site_of[i] = 0;
        self.nregs = nregs0;
        return true;
    }
    self.h.opt.inline_seen++;
    *flat_total += size + 1;
    self.flat_count++;
    return true;
}

// The instructions polymorphic call `si1 - 1` (its first case) takes in the spliced graph: per case a
// test, the call entering the body and the body, then the call itself.
fn uint OptBuild.poly_size(&self, uint si1) {
    uint n = 1;
    for (uint c = si1; c != 0; c = self.sites[(sz)c - 1].poly_next) n += 2 + self.splice_size(c - 1);
    return n;
}

// Find the nested inline sites of the calls in the body of site `si`, recursively, and widen nregs
// to hold their windows; `words` counts the bytecode of the callees of the tree. False when a call
// is not one (the body would hold a call), leaving the sites it added.
fn bool OptBuild.add_children(&self, uint si, uint* words) {
    if (!self.sites[si].has_calls) return true;
    uint count = self.sites[si].cfg.instruction_count;
    self.sites[si].child_of = mem::new_array(uint, count);
    for (uint k = 0; k < count; k++) {
        if (!inline_call_op(self.sites[si].cfg.nodes[k].view.insn.op)) continue;
        // A push the body builds as a node (OptBuild.push_call).
        if (opt_push_site(self.h, self.sites[si].cf, self.sites[si].cfg.nodes[k].view.pc)) continue;
        OptInlineSite c;
        self.rej = OptInlineReject.BUILD;
        Opcode cop = self.sites[si].cfg.nodes[k].view.insn.op;
        if (!self.inline_candidate(k, &c, si + 1)) {
            // A constructor's own reason is worth its count too: the parent's names only the opcode.
            if (cop == Opcode.NEW_OBJ && self.rej != OptInlineReject.BUILD) self.count_reject(self.rej, self.rej_op);
            self.rej_op = cop == Opcode.NEW_OBJ ? cop : Opcode.CALL;
            return false;
        }
        *words += c.cf.code_count;
        if (*words > INLINE_TREE_WORDS_MAX) {
            c.free_site();
            self.rej_op = cop == Opcode.NEW_OBJ ? cop : Opcode.CALL;
            return false;
        }
        uint ci = (uint)self.sites.len();
        self.sites.push(c);
        self.sites[si].child_of[k] = ci + 1;
        uint need = c.base + c.cf.num_regs;
        if (need > self.nregs) self.nregs = need;
        if (!self.add_children(ci, words)) return false;
    }
    return true;
}

// Splice the bodies of the flat sites into the caller's control flow graph: each call stays as the
// head, followed by its callee's instructions with their registers shifted into the call's window,
// their edges re-pointed, and every return turned into a copy of the value to the call's result
// register with an edge to the instruction after the call (OptBuild.splice); a flat body's own flat
// calls are spliced in turn after their heads. Blocks, order and liveness are then derived from the
// whole, so the merge of the returns is an ordinary phi. Each node keeps the callee's pc and feedback
// for lowering (OptBuild.context); only the register operands and the returns are rewritten.
fn bool OptBuild.flatten(&self) {
    DecodedCfg* old = &self.cfg;
    uint ocount = old.instruction_count;
    uint* fmap = mem::new_array(uint, (sz)ocount + 1);
    defer mem::free(fmap);
    uint total = 0;
    for (uint i = 0; i < ocount; i++) {
        fmap[i] = total;
        uint si1 = self.site_of[i];
        if (si1 != 0 && self.sites[(sz)si1 - 1].poly) {
            total += self.poly_size(si1);
            continue;
        }
        total++;
        if (si1 != 0 && self.sites[(sz)si1 - 1].flat) total += self.splice_size(si1 - 1);
    }
    fmap[ocount] = total;
    usz bytes = (usz)total * DecodedCfgNode::size;
    void* storage = self.h.alloc_func(self.h.heap_udata, bytes);
    if (storage == null) return false;
    mem::clear(storage, (sz)bytes);
    DecodedCfg flat = { .nodes = (DecodedCfgNode*)storage, .instruction_count = total, .word_count = old.word_count, .has_wide = old.has_wide, .storage = storage, .owner = self.h };
    self.fl_site = mem::new_array(uint, total);
    self.fl_kind = mem::new_array(uint, total);
    self.fl_local = mem::new_array(uint, total);
    self.site_fn = mem::new_array(uint, self.sites.len());
    uint* flat_site_of = mem::new_array(uint, total);
    uint* scratch = mem::new_array(uint, total);
    defer mem::free(scratch);
    for (uint i = 0; i < ocount; i++) {
        uint o = fmap[i];
        DecodedCfgNode node = old.nodes[i];
        for (uint k = 0; k < node.successor_count; k++) node.successors[k] = fmap[node.successors[k]];
        if (node.branch_target != compiler::CFG_NO_INSTRUCTION) node.branch_target = fmap[node.branch_target];
        uint si1 = self.site_of[i];
        if (si1 != 0 && self.sites[(sz)si1 - 1].poly) {
            // Per case: the test of the callee, which goes on to the next case when it is not a
            // closure of the case's function, the call entering the body, and the body. Then the call.
            uint at = o;
            for (uint c = si1; c != 0; c = self.sites[(sz)c - 1].poly_next) {
                uint enter = at + 1;
                uint next = enter + 1 + self.splice_size(c - 1);
                DecodedCfgNode t = node;
                t.successors[0] = next;
                t.successors[1] = enter;
                t.successor_count = 2;
                t.branch_target = next;
                flat.nodes[at] = t;
                self.fl_kind[at] = 5;
                flat_site_of[at] = c;
                DecodedCfgNode e = node;
                e.successors[0] = enter + 1;
                e.successor_count = 1;
                e.branch_target = compiler::CFG_NO_INSTRUCTION;
                flat.nodes[enter] = e;
                flat_site_of[enter] = c;
                self.sites[(sz)c - 1].insn = enter;
                self.splice(c - 1, enter + 1, fmap[i + 1], node.view.insn.a, &flat, flat_site_of);
                at = next;
            }
            flat.nodes[at] = node;
            continue;
        }
        if (si1 != 0) {
            OptInlineSite* s = &self.sites[(sz)si1 - 1];
            s.insn = o;
            flat_site_of[o] = si1;
            if (s.flat) {
                // The head runs into the body.
                node.successors[0] = o + 1;
                node.successor_count = 1;
                node.branch_target = compiler::CFG_NO_INSTRUCTION;
                self.splice(si1 - 1, o + 1, fmap[i + 1], node.view.insn.a, &flat, flat_site_of);
            }
        }
        flat.nodes[o] = node;
    }
    compiler::bytecode_cfg_finish(&flat, scratch);
    compiler::bytecode_cfg_free(&self.cfg);
    self.cfg = flat;
    mem::free(self.site_of);
    self.site_of = flat_site_of;
    // Liveness over the whole graph, with room for the callee windows.
    mem::free(self.live_sets);
    mem::free(self.live_words);
    uint words = (self.nregs + 32) / 32;
    self.live_sets = mem::new_array(RegSet, (usz)total * 2);
    self.live_words = mem::new_array(uint, ((usz)total * 2 + 1) * words);
    for (uint i = 0; i < total * 2; i++) self.live_sets[i] = { .words = self.live_words + (usz)i * words, .word_count = words };
    RegSet scratch_set = { .words = self.live_words + (usz)total * 2 * words, .word_count = words };
    compiler::bytecode_cfg_liveness(&self.cfg, self.live_sets, self.live_sets + total, &scratch_set, true, false, true);
    self.live_out = self.live_sets;
    self.live_in = self.live_sets + total;
    foreach (&s : self.sites) if (s.flat) self.splice_liveness(s);
    return true;
}

// The instructions the body of flat site `si` takes in the spliced graph, its flat calls' included.
fn uint OptBuild.splice_size(&self, uint si) {
    OptInlineSite* s = &self.sites[si];
    uint n = s.cfg.instruction_count;
    if (s.child_of == null) return n;
    for (uint k = 0; k < s.cfg.instruction_count; k++) {
        uint c = self.sites[si].child_of[k];
        if (c != 0 && self.sites[(sz)c - 1].flat) n += self.splice_size(c - 1);
    }
    return n;
}

// Place the body of flat site `si` at instruction `off` of the spliced graph, its returns writing
// graph register `result` and running to `join`. A constructor's return is the copy of its object
// (fl_kind 4); the CALL_S that completes a forwarding call of the body is nothing (fl_kind 3), its
// APPLY_ARGS having made the call. Every call of the body names its site at its graph instruction.
fn void OptBuild.splice(&self, uint si, uint off, uint join, uint result, DecodedCfg* flat, uint* flat_site_of) {
    DecodedCfg* cc = &self.sites[si].cfg;
    uint base = self.sites[si].base;
    bool construct = self.sites[si].construct;
    uint* child_of = self.sites[si].child_of;
    uint count = cc.instruction_count;
    uint* lmap = mem::new_array(uint, count);
    defer mem::free(lmap);
    uint at = off;
    for (uint j = 0; j < count; j++) {
        lmap[j] = at++;
        if (child_of != null && child_of[j] != 0 && self.sites[(sz)child_of[j] - 1].flat) at += self.splice_size(child_of[j] - 1);
    }
    self.sites[si].flat_off = off;
    for (uint j = 0; j < count; j++) {
        uint g = lmap[j];
        DecodedCfgNode cn = cc.nodes[j];
        inline_rebase(&cn.view.insn, base);
        for (uint k = 0; k < cn.successor_count; k++) cn.successors[k] = lmap[cn.successors[k]];
        if (cn.branch_target != compiler::CFG_NO_INSTRUCTION) cn.branch_target = lmap[cn.branch_target];
        cn.block_entry = false;
        cn.external = false;
        cn.call = false;
        self.fl_site[g] = si + 1;
        self.fl_local[g] = j;
        Opcode op = cn.view.insn.op;
        uint c1 = child_of == null ? 0 : child_of[j];
        if (c1 != 0) {
            self.sites[(sz)c1 - 1].insn = g;
            flat_site_of[g] = c1;
            if (self.sites[(sz)c1 - 1].flat) {
                cn.successors[0] = g + 1;
                cn.successor_count = 1;
                cn.branch_target = compiler::CFG_NO_INSTRUCTION;
                self.splice(c1 - 1, g + 1, lmap[j + 1], cn.view.insn.a, flat, flat_site_of);
            }
        }
        if (op == Opcode.CALL_S && j > 0 && forward_pair(cc, j - 1)) {
            cn.view.insn = { .op = Opcode.NOP };
            cn.roles = compiler::moveelim_roles[Opcode.NOP.ordinal];
            self.fl_kind[g] = 3;
        } else if (op == Opcode.RET || op == Opcode.RETUNDEF) {
            uint src = cn.view.insn.a;
            // A constructor's object, in its receiver slot, is read up to its returns.
            cn.view.insn.op = op == Opcode.RET || construct ? Opcode.LDREG : Opcode.LDUNDEF;
            cn.view.insn.a = result;
            cn.view.insn.b = construct ? base - 1 : (op == Opcode.RET ? src : 0);
            cn.view.insn.c = 0;
            cn.roles = compiler::moveelim_roles[cn.view.insn.op.ordinal];
            cn.successors[0] = join;
            cn.successor_count = 1;
            cn.branch_target = compiler::CFG_NO_INSTRUCTION;
            self.fl_kind[g] = construct ? 4 : (op == Opcode.RET ? 1 : 2);
        }
        flat.nodes[g] = cn;
    }
}

// What the spliced graph's liveness does not see of flat site `s`: the callee and receiver registers
// of its call, which an exit from anywhere in its body (its flat calls' included) stores for the frame
// it publishes; and in a forwarding body, its arguments up to its forwarding call (as forward_liveness
// for a body lowered in place; splice_ok made those instructions consecutive).
fn void OptBuild.splice_liveness(&self, OptInlineSite* s) {
    uint first = s.flat_off;
    uint last = first + self.splice_size((uint)(s - &self.sites[0]));
    for (uint g = first - 1; g < last; g++) {
        self.live_out[g].set(s.base - 2);
        if (s.method || s.construct) self.live_out[g].set(s.base - 1);
        if (g < first) continue;
        self.live_in[g].set(s.base - 2);
        if (s.method || s.construct) self.live_in[g].set(s.base - 1);
    }
    if (!s.cf.arguments_in_reg()) return;
    uint n = min(s.nargs, s.cf.num_regs);
    for (uint j = 0; j < s.cfg.instruction_count; j++) {
        DecodedInsn w = s.cfg.nodes[j].view.insn;
        if (w.op != Opcode.APPLY_ARGS) continue;
        for (uint k = 0; k <= j; k++) {
            RegSet* in = &self.live_in[first + k];
            for (uint r = 0; r < n; r++) in.set(s.base + r);
            for (uint r = w.a; r <= w.a + 2 && r < s.cf.num_regs; r++) in.set(s.base + r);
            in.set(s.base + w.c);
        }
        for (uint k = 0; k <= j; k++) self.live_out[first + k - 1].union_with(&self.live_in[first + k]);
    }
}

// A flat body that cannot be lowered: abandon this build, to be redone with the site left as a call.
fn void OptBuild.fail_flat(&self, uint si, OptInlineReject why) {
    if (self.flat_pend) return;
    self.flat_pend = true;
    self.flat_pend_site = si;
    self.flat_pend_why = why;
}

// The round is over (or cannot go on): abandon the build for the failed flat site, unless a
// numeric use asked for a typed load, which the next round builds the body with.
fn bool OptBuild.settle_flat(&self) {
    if (!self.flat_pend || self.load_changed) return false;
    OptInlineSite* s = &self.sites[self.flat_pend_site];
    if (!s.counted) self.count_reject(self.flat_pend_why, Opcode.NOP);
    s.counted = true;
    self.flat_fail = true;
    self.flat_fail_pc = s.head_pc;
    return true;
}

// The call of a flat site: the guards of the inlined call, as try_inline does, and the entry of its
// body, whose instructions follow in the graph. In a flat body the call is a nested site, whose
// OptGraph.fns entry names the body's as its parent.
fn bool OptBuild.enter_flat(&self, uint si) {
    OptInlineSite* s = &self.sites[si];
    uint callee_reg = s.base - 2;
    uint callee_node = NO_NODE;
    uint recv_node = NO_NODE;
    uint apply_node = NO_NODE;
    bool state_ok = true;
    if (s.forward) {
        state_ok = self.call_operand(callee_reg, &apply_node) && self.call_operand(callee_reg + 1, &callee_node)
            && self.call_operand(callee_reg + 2, &recv_node);
    } else if (!s.var_call) {
        state_ok = self.call_operand(callee_reg, &callee_node);
        if (state_ok && !s.construct && (s.method || callee_reg + 1 < self.caller_regs)) state_ok = self.call_operand(callee_reg + 1, &recv_node);
    }
    if (!state_ok) {
        self.fail_flat(si, OptInlineReject.STATE);
        return true;
    }
    uint parent_fn = self.cur_fn;
    uint resume = s.forward ? self.next_pc + 1 : self.next_pc;
    uint result = self.w.a;
    if (s.var_call) {
        uint closure;
        if (!self.body_closure(&closure)) {
            self.fail_flat(si, OptInlineReject.STATE);
            return true;
        }
        bool beyond = callee_reg >= self.caller_regs;
        uint load = self.add(OptOp.LOAD_VAR, beyond ? OptRep.VALUE : OptRep.NONE, NO_NODE, closure, (long)self.pc);
        self.g.nodes[load].cc = self.w.op == Opcode.CALL_VAR ? 1 : 0;
        self.snapshot(load);
        if (beyond) {
            self.set(callee_reg, load);
            callee_node = load;
        } else {
            self.kill(callee_reg);
        }
    }
    if (s.forward) {
        uint fwd = self.add(OptOp.CHECK_BUILTIN, OptRep.NONE, apply_node, NO_NODE, (long)builtins::Builtin.FUNCTION_PROTO_APPLY.ordinal);
        self.g.nodes[fwd].home = callee_reg;
        self.snapshot(fwd);
    }
    uint chk = self.add(OptOp.CHECK_CALLEE, OptRep.NONE, callee_node, recv_node, (long)(usz)s.cf);
    self.g.nodes[chk].cc = s.construct ? 2 : (s.method ? 1 : 0);
    if (s.method && !s.forward) self.settle_method(chk, callee_reg, s.cf, s);
    self.snapshot(chk);
    if (s.forward) {
        bool pending = false;
        if (!self.forward_window(s, &pending)) {
            if (pending) {
                self.inline_unsafe = true;
            } else {
                self.fail_flat(si, OptInlineReject.BUILD);
            }
            return true;
        }
    }
    if (s.construct) {
        uint object = self.add(OptOp.NEW_OBJECT, OptRep.VALUE, callee_node, NO_NODE, (long)(usz)s.cf);
        self.snapshot(object);
        self.set(callee_reg + 1, object);
        self.note_fresh(object, s.cf);
    }
    uint parent_keep = parent_fn == 0 ? 0 : self.keep_across(&self.sites[self.cur_site], self.insn, callee_reg);
    self.g.fns.push({ .f = s.cf, .reg_base = s.base, .resume_pc = resume, .remap_pc = uint::max, .remap_reg = result,
                      .parent = parent_fn, .depth = self.g.fns[parent_fn].depth + 1, .parent_keep = parent_keep, .nargs = s.nargs });
    self.site_fn[si] = (uint)self.g.fns.len() - 1;
    self.enter_args(s);
    self.inlined++;
    return true;
}

// A flat body's return: the value of graph register `ra` becomes the call's result register. A number
// is a new node in that register; a window value is copied to its slot, or beyond the caller's frame
// read into a VALUE node. A constructor's return (`construct`) is its object, which `ra` holds.
fn bool OptBuild.flat_return(&self, uint result, uint ra, bool construct = false) {
    if (ra >= self.nregs || result >= self.nregs) return false;
    uint src = self.cur[ra].node;
    if (src != NO_NODE) {
        if (construct && self.rep_of(src) != OptRep.VALUE) return false;
        if (!self.g.nodes[src].is_const()) src = self.add(OptOp.COPY, self.rep_of(src), src);
        self.set(result, src);
        return true;
    }
    if (!construct) return self.window_copy(result, 0);
    // The object in the receiver slot, within the caller's frame.
    if (ra >= self.caller_regs) return false;
    bool beyond = result >= self.caller_regs;
    uint n = self.add(OptOp.COPY_WINDOW, beyond ? OptRep.VALUE : OptRep.NONE, NO_NODE, NO_NODE, (long)ra);
    self.g.nodes[n].home = result;
    self.g.nodes[n].cc = 3;
    self.snapshot(n);
    if (beyond) {
        self.set(result, n);
    } else {
        self.kill(result);
    }
    return true;
}

// An instruction of a flat body.
fn bool OptBuild.lower_flat(&self) {
    uint kind = self.fl_kind[self.insn];
    self.inline_failed = false;
    self.inline_unsafe = false;
    bool ok = true;
    if (kind == 1 || kind == 4) {
        ok = self.flat_return(self.w.a, self.w.b, kind == 4);
    } else if (kind == 2) {
        self.store_const(self.w.a, K_UNDEF);
    } else if (kind == 3) {
        // The CALL_S of a forwarding call its APPLY_ARGS inlined.
    } else if (self.cold_field()) {
        // Never executed: leave for the callee's baseline code here, and lower nothing after it
        // on this path.
        uint n = self.add(OptOp.EXIT, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
        self.snapshot(n);
        self.cold_exit = true;
        self.cold_site = self.cur_site;
    } else {
        ok = self.lower_op();
    }
    if (!ok || self.inline_failed || self.inline_unsafe) {
        // A refusal inside the body is the site's failure, not the function's.
        self.refused = OptRefuse.NONE;
        self.fail_flat(self.cur_site, self.inline_unsafe ? OptInlineReject.UNSAFE : OptInlineReject.BUILD);
    }
    return true;
}

// Store the boxed constant `bits` to window slot `reg` (a register of an inlined body or the call's
// result): nothing is known of the register after, as a read from the window.
fn void OptBuild.store_const(&self, uint reg, long bits) {
    uint n = self.add(OptOp.STORE_CONST, OptRep.NONE, NO_NODE, NO_NODE, bits);
    self.g.nodes[n].home = reg;
    self.kill(reg);
    if (reg < self.nregs) self.const_def[reg] = n;
}

// The callee's registers on entry to its inlined body: the arguments keep their state, missing formals
// are undefined, as a frame's are, and the locals and temporaries start as nothing known.
fn void OptBuild.enter_args(&self, OptInlineSite* s) {
    uint given = min(s.nargs, s.cf.num_regs);
    for (uint r = given; r < s.cf.num_formals; r++) self.store_const(s.base + r, K_UNDEF);
    for (uint r = s.base + max(given, (uint)s.cf.num_formals); r < self.nregs; r++) self.kill(r);
}

// The registers of a forwarding call moved as th_apply_args moves them: the function `apply` runs
// into the callee register, the receiver after it, and the arguments of the forwarding body into the
// window. A register's node moves as a copy; a window value moves within the caller's frame or is read
// into a VALUE node beyond it. Those reads, which can exit, come before anything moves, so an exit
// resumes the APPLY_ARGS on the registers as they were. False when a value cannot move, with `pending`
// when a later round may build it as a node.
fn bool OptBuild.forward_window(&self, OptInlineSite* s, bool* pending) {
    OptInlineSite* ps = &self.sites[(sz)s.parent - 1];
    uint callee_reg = s.base - 2;
    uint count = min(s.nargs, s.cf.num_regs);
    // The arguments lie below the call's registers, which the moves overwrite.
    if (ps.base + count > callee_reg) return false;
    uint[2 + 32] src @noinit;
    src[0] = callee_reg + 1;
    src[1] = callee_reg + 2;
    for (uint i = 0; i < count; i++) src[2 + i] = ps.base + i;
    if (!self.move_window(&src[0], 2 + count, callee_reg, pending)) return false;
    // The count register, as APPLY_ARGS leaves it.
    self.set(self.w.c, self.const_i32((long)s.nargs));
    return true;
}

// The registers of `X.call(x, args)` shifted down by one slot, as Function.prototype.call leaves its
// window for the call it re-dispatches: X into the callee register, x after it, then the arguments.
fn bool OptBuild.call_window(&self, OptInlineSite* s, bool* pending) {
    uint callee_reg = s.base - 2;
    uint count = min(s.nargs, s.cf.num_regs);
    uint[2 + 32] src @noinit;
    for (uint m = 0; m < 2 + count; m++) src[m] = callee_reg + 1 + m;
    return self.move_window(&src[0], 2 + count, callee_reg, pending);
}

// Registers `src[m]` moved to `callee_reg + m`, in order, with each value read before any moves.
fn bool OptBuild.move_window(&self, uint* src, uint moves, uint callee_reg, bool* pending) {
    uint[2 + 32] value @noinit;
    bool[2 + 32] fresh;
    for (uint m = 0; m < moves; m++) {
        uint r = src[m];
        uint dst = callee_reg + m;
        if (r >= self.nregs || dst >= self.nregs) return false;
        value[m] = self.cur[r].node;
        if (value[m] != NO_NODE) continue;
        if (r >= self.caller_regs) {
            // Only nodes live beyond the caller's frame: a property read may become one next round.
            if (self.load_def[r] != NO_NODE) {
                self.ask_value(r);
                *pending = true;
            }
            return false;
        }
        if (dst < self.caller_regs) continue;
        uint n = self.add(OptOp.COPY_WINDOW, OptRep.VALUE, NO_NODE, NO_NODE, (long)r);
        self.g.nodes[n].cc = 3;
        self.g.nodes[n].home = dst;
        self.snapshot(n);
        value[m] = n;
        fresh[m] = true;
    }
    for (uint m = 0; m < moves; m++) {
        uint dst = callee_reg + m;
        uint v = value[m];
        if (v == NO_NODE) {
            uint n = self.add(OptOp.MOVE_WINDOW, OptRep.NONE, NO_NODE, NO_NODE, (long)src[m]);
            self.g.nodes[n].home = dst;
            self.kill(dst);
        } else if (fresh[m] || self.g.nodes[v].is_const()) {
            self.set(dst, v);
        } else {
            self.set(dst, self.add(OptOp.COPY, self.rep_of(v), v));
        }
    }
    return true;
}

// The return of an inlined body: its value becomes the call's result register. A number is a new
// node in that register; a window value is copied to its slot.
fn bool OptBuild.inline_return(&self, uint result, uint* node) {
    if (self.sites[self.cur_site].remap != uint::max) {
        *node = NO_NODE;
        return true;
    }
    uint ra = self.w.a;
    if (ra >= self.nregs || result >= self.nregs) return false;
    uint src = self.cur[ra].node;
    if (src != NO_NODE) {
        if (!self.g.nodes[src].is_const()) src = self.add(OptOp.COPY, self.rep_of(src), src);
        *node = src;
        return true;
    }
    // A nested call's result register may lie beyond the caller's frame: then a VALUE node.
    return self.window_copy(result, 0, node);
}

// The return of an inlined constructor: the object it was given as `this` is the result unless the
// body returns an object, which only a return of a number leaves certain; any other value keeps the
// site a call.
fn bool OptBuild.construct_return(&self, uint this_reg, uint* node) {
    uint object = self.cur[this_reg].node;
    if (object == NO_NODE || self.rep_of(object) != OptRep.VALUE) return false;
    if (self.w.op == Opcode.RET) {
        uint ra = self.w.a;
        if (ra >= self.nregs || self.cur[ra].node == NO_NODE || self.holds_value(ra)) return false;
    }
    *node = self.add(OptOp.COPY, OptRep.VALUE, object);
    return true;
}

// A register the guard of a nested call reads its callee or receiver from (OptBuild.try_inline):
// inside the caller's frame a value in the window, beyond it a VALUE node, which `node` receives.
// A value there that a property or global read left in the window asks for that read to be an
// VALUE node in the next round.
fn bool OptBuild.call_operand(&self, uint r, uint* node) {
    *node = NO_NODE;
    if (r < self.caller_regs) return self.in_window(r);
    if (self.holds_value(r)) {
        *node = self.cur[r].node;
        return true;
    }
    if (r < self.nregs && self.cur[r].node == NO_NODE && self.load_def[r] != NO_NODE) {
        self.ask_value(r);
        // Not a final refusal: the site waits for the round that has the node (as for a load).
        self.inline_unsafe = true;
    }
    return false;
}

// The registers of the inlined body being lowered (by its own numbering) that hold values across
// its call at `insn`: those live after it and written before it, and the call's callee and receiver.
fn uint OptBuild.keep_across(&self, OptInlineSite* p, uint insn, uint callee_reg) {
    // A flat body's instruction is one of the spliced graph.
    if (p.flat) insn = self.fl_local[insn];
    uint keep = 0;
    for (uint k = 0; k < p.cf.num_regs; k++) {
        if (p.live_out[insn].test(k) && (p.defined[insn] & (1u << k)) != 0) keep |= 1u << k;
    }
    uint c = callee_reg - p.base;
    keep |= 1u << c;
    if (c + 1 < 32) keep |= 1u << (c + 1);
    return keep;
}

// Replace the call being lowered by its callee's body when the call is an inline site and the state
// allows it; false leaves the graph as it was, for the call to be lowered as a GENERIC (which, in an
// inlined body, fails that body in turn). A call of an inlined body is a nested site: its window
// nests in the body's, its guard reads VALUE nodes for registers beyond the caller's frame, and its
// OptGraph.fns entry names the body's as its parent, whose frame an exit publishes first.
fn bool OptBuild.try_inline(&self) {
    uint si1 = 0;
    if (self.cur_fn == 0) {
        if (self.site_of != null) si1 = self.site_of[self.insn];
    } else {
        OptInlineSite* ps = &self.sites[self.cur_site];
        if (ps.flat) {
            si1 = self.site_of[self.insn];
        } else if (ps.child_of != null) {
            si1 = ps.child_of[self.insn];
        }
    }
    if (si1 == 0) return false;
    uint si = si1 - 1;
    OptInlineSite* s = &self.sites[si];
    if (s.flat) return self.enter_flat(si);
    if (self.h.opt.inline_seen >= self.h.opt.inline_max) return false;
    self.h.opt.inline_seen++;
    uint callee_reg = s.base - 2;
    uint parent_fn = self.cur_fn;
    uint parent_site = self.cur_site;
    // The function and its receiver are read from the window by the guard and by an exit.
    uint callee_node = NO_NODE;
    uint recv_node = NO_NODE;
    uint apply_node = NO_NODE;
    uint scope_node = NO_NODE;
    bool state_ok = true;
    if (s.forward || s.dotcall) {
        // Before the call moves them: `apply` or `call`, the function it runs and the receiver.
        state_ok = self.call_operand(callee_reg, &apply_node) && self.call_operand(callee_reg + 1, &callee_node)
            && self.call_operand(callee_reg + 2, &recv_node);
    } else if (s.var_call) {
        state_ok = self.body_closure(&scope_node);
    } else {
        state_ok = self.call_operand(callee_reg, &callee_node);
        // A NEW_OBJ's receiver slot receives the object the inline allocates.
        if (state_ok && !s.construct && (s.method || callee_reg + 1 < self.caller_regs)) state_ok = self.call_operand(callee_reg + 1, &recv_node);
    }
    if (!state_ok) {
        if (!s.counted && !self.inline_unsafe) self.count_reject(OptInlineReject.STATE, Opcode.NOP);
        if (!self.inline_unsafe) s.counted = true;
        return false;
    }
    uint n = self.nregs;
    OptRegState* save_cur = mem::new_array(OptRegState, n);
    uint* save_def = mem::new_array(uint, n);
    uint* save_shape = mem::new_array(uint, (usz)n + 1);
    bool* save_plain = mem::new_array(bool, (usz)n + 1);
    char* save_elem = mem::new_array(char, (usz)n + 1);
    defer { mem::free(save_cur); mem::free(save_def); mem::free(save_shape); mem::free(save_plain); mem::free(save_elem); }
    mem::copy(save_cur, self.cur, (usz)n * OptRegState::size);
    mem::copy(save_def, self.load_def, (usz)n * uint::size);
    mem::copy(save_shape, self.fact_shape, ((usz)n + 1) * uint::size);
    mem::copy(save_plain, self.fact_plain, (usz)n + 1);
    mem::copy(save_elem, self.fact_elem, (usz)n + 1);
    ulong save_bindings = self.fact_bindings;
    ulong save_captures = self.fact_captures;
    OptAvail[OPT_AVAIL_MAX] save_avail = self.avail;
    uint save_avail_n = self.avail_n;
    OptFresh[OPT_FRESH_MAX] save_fresh = self.fresh;
    uint save_fresh_n = self.fresh_n;
    sz nodes0 = self.g.nodes.len();
    sz dirty0 = self.g.dirty.len();
    sz fns0 = self.g.fns.len();
    uint site_insn = self.insn;
    // A forwarding call resumes after its CALL_S, which writes the result to the callee register.
    uint resume = s.forward ? self.next_pc + 1 : self.next_pc;
    uint result = self.w.a;
    bool parent_failed = self.inline_failed;
    bool parent_unsafe = self.inline_unsafe;

    if (s.var_call) {
        // The callee is read from its variable into the callee register, as the call would; beyond
        // the caller's frame into a VALUE node.
        bool beyond = callee_reg >= self.caller_regs;
        uint load = self.add(OptOp.LOAD_VAR, beyond ? OptRep.VALUE : OptRep.NONE, NO_NODE, scope_node, (long)self.pc);
        self.g.nodes[load].cc = self.w.op == Opcode.CALL_VAR ? 1 : 0;
        self.snapshot(load);
        if (beyond) {
            self.set(callee_reg, load);
            callee_node = load;
        } else {
            self.kill(callee_reg);
        }
    }
    // The guard resumes the call itself, in the caller's context.
    if (s.forward || s.dotcall) {
        uint fwd = self.add(OptOp.CHECK_BUILTIN, OptRep.NONE, apply_node, NO_NODE,
                            (long)(s.dotcall ? builtins::Builtin.FUNCTION_PROTO_CALL : builtins::Builtin.FUNCTION_PROTO_APPLY).ordinal);
        self.g.nodes[fwd].home = callee_reg;
        self.snapshot(fwd);
    }
    uint chk = self.add(OptOp.CHECK_CALLEE, OptRep.NONE, callee_node, recv_node, (long)(usz)s.cf);
    // Bit 2: the function and receiver are those after the callee register (`apply`, `call`).
    self.g.nodes[chk].cc = (s.construct ? 2 : (s.method ? 1 : 0)) | (s.dotcall ? 4 : 0);
    if (s.method && !s.forward && !s.dotcall) self.settle_method(chk, callee_reg, s.cf);
    self.snapshot(chk);
    bool move_pending = false;
    bool moved = true;
    if (s.forward) {
        moved = self.forward_window(s, &move_pending);
    } else if (s.dotcall) {
        moved = self.call_window(s, &move_pending);
    }
    // A constructor's object, allocated in the caller's context: its exit resumes the NEW_OBJ.
    uint object = NO_NODE;
    if (s.construct) {
        object = self.add(OptOp.NEW_OBJECT, OptRep.VALUE, callee_node, NO_NODE, (long)(usz)s.cf);
        self.snapshot(object);
        self.set(callee_reg + 1, object);
        self.note_fresh(object, s.cf);
    }

    uint remap_pc = s.remap == uint::max ? uint::max : s.cfg.nodes[s.remap].view.pc;
    uint parent_keep = parent_fn == 0 ? 0 : self.keep_across(&self.sites[parent_site], site_insn, callee_reg);
    self.g.fns.push({ .f = s.cf, .reg_base = s.base, .resume_pc = resume, .remap_pc = remap_pc, .remap_reg = result,
                      .parent = parent_fn, .depth = self.g.fns[parent_fn].depth + 1, .parent_keep = parent_keep, .nargs = s.nargs });
    self.cur_fn = (uint)self.g.fns.len() - 1;
    self.cur_site = si;
    self.inline_failed = false;
    self.inline_unsafe = move_pending;
    self.enter_args(s);
    bool ok = moved;
    uint result_node = NO_NODE;
    for (uint k = 0; k < s.cfg.instruction_count && ok; k++) {
        self.inline_context(s, k);
        if (s.construct && (self.w.op == Opcode.RET || self.w.op == Opcode.RETUNDEF)) {
            ok = self.construct_return(callee_reg + 1, &result_node);
        } else if (self.w.op == Opcode.RET) {
            ok = self.inline_return(result, &result_node);
        } else if (self.w.op == Opcode.RETUNDEF) {
            self.store_const(result, K_UNDEF);
        } else {
            ok = self.lower();
        }
        if (self.inline_failed) ok = false;
        // A nested site's lowering moved the sites list.
        s = &self.sites[si];
    }
    bool unsafe = self.inline_unsafe;
    if (unsafe) ok = false;
    self.cur_fn = parent_fn;
    self.cur_site = parent_site;
    if (parent_fn == 0 || self.sites[parent_site].flat) {
        self.context(site_insn);
    } else {
        self.inline_context(&self.sites[parent_site], site_insn);
    }
    self.inline_failed = parent_failed;
    self.inline_unsafe = parent_unsafe;
    if (!ok) {
        // A load a later round builds as a VALUE node is not a final refusal.
        bool pending = unsafe && self.load_changed;

        if (!s.counted && !pending) self.count_reject(unsafe ? OptInlineReject.UNSAFE : OptInlineReject.BUILD, Opcode.NOP);
        if (!pending) s.counted = true;
        // The body around a nested site waits with it.
        if (pending && parent_fn != 0) self.inline_unsafe = true;
        self.g.nodes.size = nodes0;
        self.g.dirty.size = dirty0;
        self.g.fns.size = fns0;
        mem::copy(self.cur, save_cur, (usz)n * OptRegState::size);
        mem::copy(self.load_def, save_def, (usz)n * uint::size);
        mem::copy(self.fact_shape, save_shape, ((usz)n + 1) * uint::size);
        mem::copy(self.fact_plain, save_plain, (usz)n + 1);
        mem::copy(self.fact_elem, save_elem, (usz)n + 1);
        self.fact_bindings = save_bindings;
        self.fact_captures = save_captures;
        self.avail = save_avail;
        self.avail_n = save_avail_n;
        self.fresh = save_fresh;
        self.fresh_n = save_fresh_n;
        if (parent_fn == 0) self.refused = OptRefuse.NONE;
        return false;
    }
    // What a call leaves: its window and everything above it dead, then the result.
    bool remapped = s.remap != uint::max;
    for (uint r = callee_reg; r < n; r++) if (!remapped || r != result) self.kill(r);
    if (result_node != NO_NODE) {
        self.set(result, result_node);
    } else if (!remapped) {
        self.kill(result);
    }
    self.inlined++;
    return true;
}


// The test of the callee before case `site_of[insn] - 1` of a polymorphic call: the case's body when
// the callee register holds a closure of its function (BRANCH_CALLEE falls through), else the next
// test or the call itself.
fn bool OptBuild.callee_test(&self) {
    uint si = self.site_of[self.insn] - 1;
    OptInlineSite* s = &self.sites[si];
    uint node = NO_NODE;
    if (!self.call_operand(s.base - 2, &node)) {
        self.fail_flat(si, OptInlineReject.STATE);
        // The test still ends the block.
        return self.terminator(OptOp.JUMP);
    }
    // The first test sees the read of the callee; the cases' bodies, and the later tests, start
    // blocks of their own.
    CompiledFunction* f;
    uint pc;
    bool proven;
    if (s.method && self.method_read(s.base - 2, &f, &pc, &proven)) {
        for (uint c = si + 1; c != 0; c = self.sites[(sz)c - 1].poly_next) {
            self.sites[(sz)c - 1].method_read = f;
            self.sites[(sz)c - 1].method_read_pc = pc;
        }
    }
    uint t = self.add(OptOp.BRANCH_CALLEE, OptRep.NONE, node, NO_NODE, (long)(usz)s.cf);
    if (s.method && s.method_read != null) self.g.nodes[t].key = self.read_constant(s.method_read, s.method_read_pc, s.cf);
    return true;
}

// Lower instruction `self.insn`.
fn bool OptBuild.lower(&self) {
    if (self.g.region.end != 0 && self.insn >= self.cfg.exit_first) return self.region_exit();
    if (self.fl_kind != null && self.fl_kind[self.insn] == 5) return self.callee_test();
    // The body of a flat site whose call did not enter it this round, which is abandoned.
    if (self.cur_fn == 0 && self.fl_site != null && self.fl_site[self.insn] != 0) return true;
    if (self.cur_fn != 0 && self.sites[self.cur_site].flat) return self.lower_flat();
    return self.lower_op();
}

fn bool OptBuild.lower_op(&self) {
    DecodedInsn w = self.w;
    Opcode op = w.op;
    uint ra = w.a;
    uint rb = w.b;
    uint rc = w.c;
    switch (op) {
        case LDINT:
            self.set(ra, self.const_i32((long)w.get_sbc()));
        case LDCONST:
            uint index = w.get_bc();
            if (!self.consts_ok || index >= self.cur_f().const_count) return self.generic();
            TVal v = self.cur_f().constants[index];
            if (v.is_fastint()) {
                long x = v.get_fastint();
                if (x >= -2147483648 && x <= 2147483647) {
                    self.set(ra, self.const_i32(x));
                } else {
                    self.set(ra, self.const_f64((double)x));
                }
            } else if (v.is_number()) {
                self.set(ra, self.const_f64(v.get_number()));
            } else {
                return self.generic();
            }
        case LDREG:
        case TONUMERIC:
            if (rb >= self.nregs) return self.generic();
            // A property read's result still in the window may be wanted as an object node.
            if (self.cur[rb].node == NO_NODE && op == Opcode.LDREG) self.ask_value(rb);
            // A window value moved as it is, typically an argument of a call: a copy, which leaves
            // the values held in registers in place where baseline code would not.
            if (self.cur[rb].node == NO_NODE && op == Opcode.LDREG) {
                if (!self.window_copy(ra, 2)) return false;
                self.same_facts(ra, rb);
                return true;
            }
            if (self.cur[rb].node == NO_NODE) return self.generic();
            if (op == Opcode.TONUMERIC && self.holds_value(rb)) return self.generic();
            uint src = self.cur[rb].node;
            if (!self.g.nodes[src].is_const()) src = self.add(OptOp.COPY, self.rep_of(src), src);
            self.set(ra, src);
            self.same_facts(ra, rb);
        case ADD: case ADD_FUSED:
            return self.arith(OptOp.ADD_I32, OptOp.ADD_F64, rb, rc, false, 0);
        case SUB:
            return self.arith(OptOp.SUB_I32, OptOp.SUB_F64, rb, rc, false, 0);
        case MUL:
            return self.arith(OptOp.MUL_I32, OptOp.MUL_F64, rb, rc, false, 0);
        case ADDI:
            if (self.wide) return self.generic();
            return self.arith(OptOp.ADD_I32, OptOp.ADD_F64, rb, NO_NODE, true, (long)(ichar)rc);
        case SUBI:
            if (self.wide) return self.generic();
            return self.arith(OptOp.SUB_I32, OptOp.SUB_F64, rb, NO_NODE, true, (long)(ichar)rc);
        case MULI:
            if (self.wide) return self.generic();
            return self.arith(OptOp.MUL_I32, OptOp.MUL_F64, rb, NO_NODE, true, (long)(ichar)rc);
        case INC:
        case INC_LT:
            return self.arith(OptOp.ADD_I32, OptOp.ADD_F64, ra, NO_NODE, true, 1);
        case DEC:
            return self.arith(OptOp.SUB_I32, OptOp.SUB_F64, ra, NO_NODE, true, 1);
        case DIV:
            char fb = self.feedback();
            if ((fb & (hobject::FB_STR | hobject::FB_OTHER)) != 0) return self.generic();
            uint x = self.operand(rb, OptRep.FLOAT64);
            uint y = self.operand(rc, OptRep.FLOAT64);
            if (x == NO_NODE || y == NO_NODE) return self.generic();
            self.set(ra, self.add(OptOp.DIV_F64, OptRep.FLOAT64, x, y));
        case BAND:
            return self.bitop(OptOp.AND_I32, rb, rc, false, 0);
        case BOR:
            return self.bitop(OptOp.OR_I32, rb, rc, false, 0);
        case BXOR:
            return self.bitop(OptOp.XOR_I32, rb, rc, false, 0);
        case SHL:
            return self.bitop(OptOp.SHL_I32, rb, rc, false, 0);
        case SHR:
            return self.bitop(OptOp.SAR_I32, rb, rc, false, 0);
        case USHR:
            return self.bitop(OptOp.SHR_I32, rb, rc, false, 0);
        case BANDI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.AND_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case BORI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.OR_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case BXORI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.XOR_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case SHLI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.SHL_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case SHRI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.SAR_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case USHRI:
            if (self.wide) return self.generic();
            return self.bitop(OptOp.SHR_I32, rb, NO_NODE, true, bytecode::imm_value(op, rc));
        case JUMP:
            return self.terminator(OptOp.JUMP);
        case IF_TRUE:
        case IF_FALSE:
            return self.truth_branch();
        case BREAK:
        case CONTINUE:
            return self.refuse_op(op);
        case LDUNDEF: case LDNULL: case LDTRUE: case LDFALSE:
            long kv;
            switch (op) {
                case LDUNDEF: kv = K_UNDEF;
                case LDNULL: kv = K_NULL;
                default: kv = op == LDTRUE ? K_BOOL | 1 : K_BOOL;
            }
            // A register the body never reads again needs no value.
            if (self.cur_fn == 0) {
                // The function's own constant load: a store to the window slot.
            } else if (self.sites[self.cur_site].flat) {
                if (!self.live_out[self.insn].test(ra)) {
                    self.kill(ra);
                    return true;
                }
            } else {
                uint k = self.cur_cfg().nodes[self.insn].view.insn.a;
                if (self.w.a == k + self.sites[self.cur_site].base && !self.sites[self.cur_site].live_out[self.insn].test(k)) {
                    self.kill(ra);
                    return true;
                }
            }
            self.store_const(ra, kv);
        case GETCAP:
            return self.get_cap();
        case GETGLOBAL:
            // A read that has left through the slow path repeatedly runs the baseline's.
            if (self.cur_fn == 0 && opt_site_banned(self.f, self.f, self.next_pc - 1)) return self.generic();
            return self.get_global();
        case GETVAR:
            if (self.cur_fn == 0) return self.generic();
            return self.get_scoped();
        case LDTHIS:
            if (self.cur_fn == 0) {
                if (opt_site_banned(self.f, self.f, self.next_pc - 1)) return self.generic();
                return self.window_copy(self.w.a, 4);
            }
            return self.load_this();
        case GETPROP:
            return self.get_elem();
        case GETPROPC:
        case GETPROPC_CACHED:
        case GETTHISC:
            return self.get_field();
        case PUTPROP:
            return self.put_elem();
        case PUTPROPC:
        case PUTTHISC:
            return self.put_field();
        case UNM:
            return self.negate();
        case BNOT:
            // ~x is x ^ -1 for ToInt32(x).
            return self.bitop(OptOp.XOR_I32, rb, NO_NODE, true, -1);
        case MOD:
            return self.modulo();
        case EQ: case NEQ: case SEQ: case SNEQ: case LT: case LE: case GT: case GE:
            return self.compare_value();
        case LNOT:
            return self.not_value();
        case THROW:
            return self.throw_exit();
        case TYPEOF:
            return self.typeof_value();
        case NEWOBJ:
        case NEWOBJ_SHAPE:
        case NEWARR:
        case NEWARR_CONST:
            return self.alloc_value();
        case INIT_SLOT:
            return self.init_slot();
        case CALL:
        case CALL_UNDEF_THIS:
        case CALL_VAR:
        case CALL_GLOBAL:
        case NEW_OBJ:
        case APPLY_ARGS:
            if (self.push_call()) return true;
            if (self.math_call()) return true;
            if (self.try_inline()) return true;
            return self.generic();
        case CALL_S:
            // The second half of a forwarding call its APPLY_ARGS inlined (an inlined body that
            // gets here has lowered that).
            if (self.cur_fn != 0 && self.insn > 0 && forward_pair(self.cur_cfg(), self.insn - 1)) return true;
            return self.generic();
        default:
            if (op == Opcode.JMP_SEQ || op == Opcode.JMP_SNEQ || (op.ordinal >= Opcode.JMP_EQ.ordinal && op.ordinal <= Opcode.JMP_NNULL.ordinal)) return self.equality_branch();
            if (is_jmp_reg(op) || is_jmp_imm(op)) return self.cmp_branch();
            if (bytecode::is_cmp_branch(op)) return self.refuse_op(op);
            return self.generic();
    }
    return true;
}


// --- Building ---

// The override recorded for register `reg` of the block at `pos`: 0 for none,
// else the rep's ordinal (NONE meaning the register is Window).
fn int OptBuild.override_of(&self, uint pos, uint reg) {
    foreach (o : self.overrides) if (o.block == pos && o.reg == reg) return (int)o.rep.ordinal + 1;
    return 0;
}

// Record that the phi for `reg` at `pos` is `rep`; whether that changed anything.
fn bool OptBuild.set_override(&self, uint pos, uint reg, OptRep rep) {
    foreach (&o : self.overrides) {
        if (o.block != pos || o.reg != reg) continue;
        if (o.rep == rep) return false;
        o.rep = rep;
        return true;
    }
    self.overrides.push({ .block = pos, .reg = reg, .rep = rep });
    return true;
}

fn void OptBuild.context(&self, uint i) {
    DecodedCfgNode* node = &self.cfg.nodes[i];
    if (self.fl_site != null) {
        uint si1 = self.fl_site[i];
        self.cur_site = si1 == 0 ? 0 : si1 - 1;
        self.cur_fn = si1 == 0 ? 0 : self.site_fn[si1 - 1];
    }
    self.insn = i;
    self.pc = node.view.pc;
    self.next_pc = node.view.next_pc;
    self.w = node.view.insn;
    self.wide = node.view.wide;
}

// The state a block starts in: inherited from its single predecessor, or merged
// from its predecessors with phis where all of them hold a numeric node.
fn void OptBuild.begin_block(&self, uint pos) {
    uint b = self.rpo[pos];
    uint first_insn = self.b_first[b];
    self.context(first_insn);
    OptBlock blk = { .first = (uint)self.g.nodes.len(), .pc = self.pc };
    self.fresh_n = 0;
    for (uint r = 0; r < self.nregs; r++) {
        self.cur[r] = { .node = NO_NODE, .dirty = false };
        self.load_def[r] = NO_NODE;
        self.const_def[r] = NO_NODE;
    }
    uint fwd = 0;
    uint back = 0;
    uint single = 0;
    foreach (p : self.preds(pos)) {
        if (p < pos) {
            if (!self.dead[p]) { fwd++; single = p; }
        } else {
            back++;
        }
    }
    // Facts cross a block start as what every built way in agrees on. A loop header keeps those
    // its back edges bring as well (head_facts); else a back edge may come from any GENERIC. An
    // OSR entry proves them for the frame the baseline code hands over (OptCg.emit_entry_facts),
    // which holds no field value in a node. A capture record a frame proved stays proved.
    bool osr = self.osr_target[first_insn];
    if (fwd == 0) {
        self.forget_facts();
        self.fact_captures = 0;
    } else {
        self.meet_facts(pos);
        if (osr) {
            // Of the caller's frame alone, and `this`.
            for (uint r = self.caller_regs; r < self.nregs; r++) {
                self.fact_shape[r] = heap::SHAPE_NONE;
                self.fact_elem[r] = 0;
            }
            self.avail_n = 0;
        }
        if (back != 0 && self.loop_facts) {
            self.head_facts(pos);
        } else if (back != 0) {
            self.forget_facts();
        }
    }
    blk.header = back > 0;
    blk.loop_end = self.loop_end[pos];
    if (pos == 0 && self.g.region.end != 0) {
        self.region_phis(first_insn);
    } else if (pos != 0) {
        bool merge = fwd + back >= 2;
        for (uint r = 0; r < self.nregs; r++) {
            if (!self.live_in[first_insn].test(r)) continue;
            if (!merge) {
                self.cur[r] = self.ends[(usz)single * self.nregs + r];
                continue;
            }
            bool numeric = true;
            OptRep rep = OptRep.INT32;
            foreach (p : self.preds(pos)) {
                if (p >= pos || self.dead[p]) continue;
                OptRegState s = self.ends[(usz)p * self.nregs + r];
                if (s.node == NO_NODE || self.rep_of(s.node) == OptRep.VALUE) { numeric = false; break; }
                if (self.rep_of(s.node) == OptRep.FLOAT64) rep = OptRep.FLOAT64;
            }
            if (!numeric) {
                if (back == 0) self.cur[r] = self.joined_value(pos, r);
                continue;
            }
            int ov = self.override_of(pos, r);
            if (ov == (int)OptRep.NONE.ordinal + 1) continue;
            if (ov == (int)OptRep.FLOAT64.ordinal + 1) rep = OptRep.FLOAT64;
            if (self.windowed != null && opt_join_windowed(self.windowed, pos, r)) continue;
            uint phi = self.add(OptOp.PHI, rep, NO_NODE, NO_NODE, (long)r);
            self.g.nodes[phi].home = r;
            self.cur[r] = { .node = phi, .dirty = true };
        }
        // A phi's slot holds it.
        for (uint r = 0; r < self.nregs; r++) {
            uint node = self.cur[r].node;
            if (node != NO_NODE && node >= blk.first && self.g.nodes[node].op == OptOp.PHI) self.drop_reg(r, node);
        }
    }
    if (blk.header) {
        blk.entry_first = (uint)self.g.dirty.len();
        for (uint r = 0; r < self.nregs; r++) {
            if (self.cur[r].node != NO_NODE && self.cur[r].dirty) self.g.dirty.push({ .reg = r, .node = self.cur[r].node });
        }
        blk.entry_count = (uint)self.g.dirty.len() - blk.entry_first;
    }
    if (osr) {
        blk.osr = true;
        blk.osr_first = (uint)self.g.dirty.len();
        for (uint r = 0; r < self.nregs; r++) {
            uint node = self.cur[r].node;
            if (node != NO_NODE && !self.g.nodes[node].is_const()) self.g.dirty.push({ .reg = r, .node = node });
        }
        blk.osr_count = (uint)self.g.dirty.len() - blk.osr_first;
        blk.fact_first = (uint)self.g.entry_facts.len();
        for (uint r = 0; r <= self.nregs; r++) {
            if (self.fact_shape[r] == heap::SHAPE_NONE && self.fact_elem[r] == 0) continue;
            OptEntryFact fact = { .reg = r == self.nregs ? OPT_THIS : r, .shape = self.fact_shape[r], .elem = self.fact_elem[r] };
            fact.plain = fact.shape != heap::SHAPE_NONE && self.fact_plain[r];
            self.g.entry_facts.push(fact);
        }
        blk.fact_count = (uint)self.g.entry_facts.len() - blk.fact_first;
        blk.bindings = self.fact_bindings;
        blk.captures = self.fact_captures;
    }
    mem::copy(&self.entries[(usz)pos * self.nregs], self.cur, (usz)self.nregs * OptRegState::size);
    self.g.blocks.push(blk);
    // Reached only through unconditional exits: a body's block gets one of its own.
    if (pos != 0 && fwd == 0 && back == 0) {
        if (self.fl_site == null || self.fl_site[first_insn] == 0) {
            self.fail_flat(self.cold_site, OptInlineReject.BUILD);
        } else {
            self.dead[pos] = true;
            uint n = self.add(OptOp.EXIT, OptRep.NONE, NO_NODE, NO_NODE, (long)self.pc);
            self.snapshot(n);
        }
    }
}

// Register `r` at the block at `pos`, a join of forward edges, when every predecessor holds an
// VALUE node in it: the one node, kept where it is with no store on the edges, or a phi of the
// nodes that differ (of booleans when all are). A nested call's callee or receiver beyond the
// caller's frame cannot be stored there at all. Else the window.
fn OptRegState OptBuild.joined_value(&self, uint pos, uint r) {
    OptRegState same = { .node = NO_NODE };
    bool differ = false;
    bool boolean = true;
    foreach (p : self.preds(pos)) {
        if (p >= pos || self.dead[p]) continue;
        OptRegState s = self.ends[(usz)p * self.nregs + r];
        if (s.node == NO_NODE || self.rep_of(s.node) != OptRep.VALUE) return { .node = NO_NODE };
        differ |= same.node != NO_NODE && s.node != same.node;
        boolean = boolean && self.g.is_boolean(&self.g.nodes[s.node]);
        same.node = s.node;
        same.dirty |= s.dirty;
    }
    if (!differ) return same;
    if (self.windowed != null && opt_join_windowed(self.windowed, pos, r)) return { .node = NO_NODE };
    same.node = self.add(OptOp.PHI, OptRep.VALUE, NO_NODE, NO_NODE, (long)r);
    self.g.nodes[same.node].home = r;
    self.g.nodes[same.node].cc = boolean ? 1 : 0;
    return same;
}

fn bool is_terminator_op(Opcode op) {
    return op == Opcode.JUMP || op == Opcode.IF_TRUE || op == Opcode.IF_FALSE || bytecode::is_cmp_branch(op);
}

fn void OptBuild.end_block(&self, uint pos) {
    uint b = self.rpo[pos];
    uint last = self.b_last[b];
    self.context(last);
    DecodedCfgNode* node = &self.cfg.nodes[last];
    OptBlock* blk = &self.g.blocks[pos];
    if (self.dead[pos]) {
        blk.succ_count = 0;
        blk.end = (uint)self.g.nodes.len();
        self.save_ends(pos);
        return;
    }
    blk.succ_count = node.successor_count;
    for (uint k = 0; k < blk.succ_count; k++) blk.succ[k] = self.pos_of[self.succ_block(b, k)];
    bool test = self.fl_kind != null && self.fl_kind[last] == 5;
    if (blk.succ_count == 1 && is_terminator_op(node.view.insn.op) && node.view.insn.op != Opcode.JUMP) {
        blk.succ[1] = blk.succ[0];
        blk.succ_count = 2;
    }
    if (blk.succ_count != 0 && !test && !is_terminator_op(node.view.insn.op)) self.terminator(OptOp.JUMP);
    blk.end = (uint)self.g.nodes.len();
    self.save_ends(pos);
}

// Record the register states and facts the block at `pos` ends with.
fn void OptBuild.save_ends(&self, uint pos) {
    sz w = (sz)self.nregs + 1;
    mem::copy(&self.ends[(usz)pos * self.nregs], self.cur, (usz)self.nregs * OptRegState::size);
    mem::copy(&self.end_shape[(sz)pos * w], self.fact_shape, w * uint::size);
    mem::copy(&self.end_plain[(sz)pos * w], self.fact_plain, w);
    mem::copy(&self.end_elem[(sz)pos * w], self.fact_elem, w);
    self.end_bindings[pos] = self.fact_bindings;
    self.end_captures[pos] = self.fact_captures;
    mem::copy(&self.end_avail[(usz)pos * OPT_AVAIL_MAX], &self.avail, (usz)self.avail_n * OptAvail::size);
    self.end_avail_n[pos] = (char)self.avail_n;
}

// The facts at the start of the block at `pos`: those every built block leading to it ends with.
fn void OptBuild.meet_facts(&self, uint pos) {
    usz w = (usz)self.nregs + 1;
    bool first = true;
    foreach (p : self.preds(pos)) {
        if (p >= pos || self.dead[p]) continue;
        uint* shape = &self.end_shape[(usz)p * w];
        bool* plain = &self.end_plain[(usz)p * w];
        char* elem = &self.end_elem[(usz)p * w];
        self.fact_bindings = first ? self.end_bindings[p] : self.fact_bindings & self.end_bindings[p];
        self.fact_captures = first ? self.end_captures[p] : self.fact_captures & self.end_captures[p];
        OptAvail[] avail = self.end_avail[(usz)p * OPT_AVAIL_MAX:self.end_avail_n[p]];
        if (first) {
            self.avail[:avail.len] = avail[..];
            self.avail_n = (uint)avail.len;
        } else {
            uint kept = 0;
            for (uint i = 0; i < self.avail_n; i++) {
                bool all = false;
                foreach (e : avail) all = all || e.same(self.avail[i]);
                if (all) self.avail[kept++] = self.avail[i];
            }
            self.avail_n = kept;
        }
        for (usz r = 0; r < w; r++) {
            if (first) {
                self.fact_shape[r] = shape[r];
                self.fact_plain[r] = plain[r];
                self.fact_elem[r] = elem[r];
            } else {
                if (self.fact_shape[r] != shape[r]) self.fact_shape[r] = heap::SHAPE_NONE;
                self.fact_plain[r] = self.fact_plain[r] && plain[r];
                self.fact_elem[r] = min(self.fact_elem[r], elem[r]);
            }
        }
        first = false;
    }
}

// The facts the loop header at `pos` starts with, from those its forward edges agree on: the ones
// its back edges were not found to lose in an earlier round, recorded as this round's assumption.
// No field value is held across it.
fn void OptBuild.head_facts(&self, uint pos) {
    usz w = (usz)self.nregs + 1;
    usz at = (usz)pos * w;
    bool set = self.head_set[pos];
    for (usz r = 0; r < w; r++) {
        if (set) {
            if (self.head_shape[at + r] != self.fact_shape[r]) self.fact_shape[r] = heap::SHAPE_NONE;
            self.fact_plain[r] = self.fact_plain[r] && self.head_plain[at + r];
            self.fact_elem[r] = min(self.fact_elem[r], self.head_elem[at + r]);
        }
        self.head_shape[at + r] = self.fact_shape[r];
        self.head_plain[at + r] = self.fact_shape[r] != heap::SHAPE_NONE && self.fact_plain[r];
        self.head_elem[at + r] = self.fact_elem[r];
    }
    if (set) {
        self.fact_bindings &= self.head_bindings[pos];
        self.fact_captures &= self.head_captures[pos];
    }
    self.head_bindings[pos] = self.fact_bindings;
    self.head_captures[pos] = self.fact_captures;
    self.head_set[pos] = true;
    self.avail_n = 0;
}

// Drop from the assumption of the loop header at `pos` what its back edge from the block at `p`
// does not bring. Whether it shrank.
fn bool OptBuild.meet_head(&self, uint pos, uint p) {
    usz w = (usz)self.nregs + 1;
    usz at = (usz)pos * w;
    usz end = (usz)p * w;
    bool changed = false;
    for (usz r = 0; r < w; r++) {
        if (self.head_shape[at + r] != heap::SHAPE_NONE && self.head_shape[at + r] != self.end_shape[end + r]) {
            self.head_shape[at + r] = heap::SHAPE_NONE;
            self.head_plain[at + r] = false;
            changed = true;
        }
        if (self.head_plain[at + r] && !self.end_plain[end + r]) {
            self.head_plain[at + r] = false;
            changed = true;
        }
        if (self.head_elem[at + r] > self.end_elem[end + r]) {
            self.head_elem[at + r] = self.end_elem[end + r];
            changed = true;
        }
    }
    ulong bindings = self.head_bindings[pos] & self.end_bindings[p];
    ulong captures = self.head_captures[pos] & self.end_captures[p];
    changed |= bindings != self.head_bindings[pos] || captures != self.head_captures[pos];
    self.head_bindings[pos] = bindings;
    self.head_captures[pos] = captures;
    return changed;
}

// The phis of a region's header, which has no forward predecessor to speculate from: one for each
// register that repair found a back edge to bring a number into (region_carried).
fn void OptBuild.region_phis(&self, uint first_insn) {
    for (uint r = 0; r < self.nregs; r++) {
        if (!self.live_in[first_insn].test(r)) continue;
        int ov = self.override_of(0, r);
        if (ov == 0 || ov == (int)OptRep.NONE.ordinal + 1) continue;
        if (self.windowed != null && opt_join_windowed(self.windowed, 0, r)) continue;
        OptRep rep = ov == (int)OptRep.FLOAT64.ordinal + 1 ? OptRep.FLOAT64 : OptRep.INT32;
        uint phi = self.add(OptOp.PHI, rep, NO_NODE, NO_NODE, (long)r);
        self.g.nodes[phi].home = r;
        self.cur[r] = { .node = phi, .dirty = true };
    }
}

// A region's header phis: a register that a back edge brings a number into, and that held a
// number in the window of the frame the region was built for, gets one, of the window value's
// representation when that is the wider. Whether any was added.
fn bool OptBuild.region_carried(&self) {
    bool changed = false;
    uint first_insn = self.b_first[self.rpo[0]];
    foreach (p : self.preds(0)) {
        for (uint r = 0; r < self.nregs; r++) {
            if (!self.live_in[first_insn].test(r) || self.override_of(0, r) != 0) continue;
            uint src = self.ends[(usz)p * self.nregs + r].node;
            if (src == NO_NODE) continue;
            OptRep rep = self.rep_of(src);
            if (rep == OptRep.VALUE) continue;
            TVal* regs = self.g.region.regs;
            if (regs != null && !regs[r].is_number()) {
                changed |= self.set_override(0, r, OptRep.NONE);
                continue;
            }
            changed |= self.set_override(0, r, regs == null || regs[r].is_fastint() ? rep : OptRep.FLOAT64);
        }
    }
    return changed;
}

fn bool OptBuild.build_round(&self) {
    self.g.clear();
    self.g.fns.size = 1;
    self.inlined = 0;
    self.flat_pend = false;
    self.void_round = false;
    for (uint pos = 0; pos < self.nrpo; pos++) self.dead[pos] = false;
    if (self.site_fn != null) mem::clear(self.site_fn, self.sites.len() * uint::size);
    for (uint pos = 0; pos < self.nrpo; pos++) {
        self.pos = pos;
        self.cold_exit = false;
        self.begin_block(pos);
        uint b = self.rpo[pos];
        for (uint i = self.b_first[b]; i <= self.b_last[b] && !self.dead[pos]; i++) {
            self.context(i);
            if (!self.lower()) {
                if (self.refused == OptRefuse.NONE) self.refuse(OptRefuse.FUNCTION);
                self.settle_flat();
                return false;
            }
            if (self.cold_exit) self.dead[pos] = true;
        }
        self.end_block(pos);
    }
    if (self.settle_flat()) {
        self.refuse(OptRefuse.FUNCTION);
        return false;
    }
    self.void_round = self.flat_pend;
    return true;
}

// Check each back edge against the phis its header speculated; record an
// override for each that disagrees. Returns whether any was recorded.
fn bool OptBuild.repair(&self) {
    bool changed = self.g.region.end != 0 && self.region_carried();
    for (uint pos = 0; pos < self.nrpo; pos++) {
        if (!self.g.blocks[pos].header) continue;
        uint first_node = self.g.blocks[pos].first;
        uint end_node = self.g.blocks[pos].end;
        foreach (p : self.preds(pos)) {
            if (p < pos) continue;
            if (self.loop_facts && self.head_set[pos] && !self.dead[p]) changed |= self.meet_head(pos, p);
            for (uint r = 0; r < self.nregs; r++) {
                uint phi = self.entries[(usz)pos * self.nregs + r].node;
                if (phi == NO_NODE || phi < first_node || phi >= end_node || self.g.nodes[phi].op != OptOp.PHI) continue;
                uint src = self.ends[(usz)p * self.nregs + r].node;
                if (src == NO_NODE || self.rep_of(src) == OptRep.VALUE) {
                    changed |= self.set_override(pos, r, OptRep.NONE);
                } else if (self.rep_of(src) == OptRep.FLOAT64 && self.g.nodes[phi].rep == OptRep.INT32) {
                    changed |= self.set_override(pos, r, OptRep.FLOAT64);
                }
            }
        }
    }
    return changed;
}

// The moves along each edge: the phi inputs, and the dirty registers that are
// Window in the successor.
fn bool OptBuild.compute_edges(&self) {
    for (uint pos = 0; pos < self.nrpo; pos++) {
        OptBlock* blk = &self.g.blocks[pos];
        for (uint e = 0; e < blk.succ_count; e++) {
            uint s = blk.succ[e];
            uint first_insn = self.b_first[self.rpo[s]];
            uint s_first = self.g.blocks[s].first;
            uint s_end = self.g.blocks[s].end;
            blk.move_first[e] = (uint)self.g.moves.len();
            for (uint r = 0; r < self.nregs; r++) {
                if (!self.live_in[first_insn].test(r)) continue;
                OptRegState sn = self.entries[(usz)s * self.nregs + r];
                OptRegState pn = self.ends[(usz)pos * self.nregs + r];
                if (sn.node != NO_NODE) {
                    if (sn.node >= s_first && sn.node < s_end && self.g.nodes[sn.node].op == OptOp.PHI) {
                        self.g.moves.push({ .dst = sn.node, .src = pn.node, .slot = r });
                    }
                } else if (pn.node != NO_NODE && pn.dirty) {
                    // A VALUE node of an inlined body that must be stored beyond the caller's
                    // frame on this edge: the site is built as a call instead.
                    if (self.g.nodes[pn.node].rep == OptRep.VALUE && r >= self.caller_regs && !self.g.is_boolean(&self.g.nodes[pn.node])) {
                        uint fi = self.g.nodes[pn.node].fidx;
                        for (uint si = 0; si < (uint)self.sites.len(); si++) {
                            if (self.site_fn[si] != fi || !self.sites[si].flat) continue;
                            if (!self.sites[si].counted) self.count_reject(OptInlineReject.UNSAFE, Opcode.NOP);
                            self.sites[si].counted = true;
                            self.flat_fail = true;
                            self.flat_fail_pc = self.sites[si].head_pc;
                            return false;
                        }
                    }
                    self.g.moves.push({ .dst = NO_NODE, .src = pn.node, .slot = r });
                }
            }
            blk.move_count[e] = (uint)self.g.moves.len() - blk.move_first[e];
        }
    }
    return true;
}

// Build the graph of `f` into `g`. Returns NONE on success, else why not. A flat inline site whose
// body cannot be lowered is left as a call and the graph is built again.
// The joins in `windowed` keep the value of their register in its window slot instead of a phi.
fn OptRefuse opt_build_graph(Heap* h, CompiledFunction* f, OptGraph* g, OptBuild* b, Opcode* refused_op, bool no_inline, List{OptJoin}* windowed = null) {
    uint[16] exclude;
    uint excluded = 0;
    while (true) {
        OptRefuse why = opt_build_once(h, f, g, b, refused_op, no_inline, &exclude[0], excluded, windowed);
        if (why == OptRefuse.NONE || !b.flat_fail || excluded == exclude.len) return why;
        exclude[excluded++] = b.flat_fail_pc;
        b.free();
    }
}

fn OptRefuse opt_build_once(Heap* h, CompiledFunction* f, OptGraph* g, OptBuild* b, Opcode* refused_op, bool no_inline, uint* exclude, uint exclude_count, List{OptJoin}* windowed) {
    *b = {};
    b.windowed = windowed;
    b.exclude = exclude;
    b.exclude_count = exclude_count;
    b.no_inline = no_inline;
    b.h = h;
    b.f = f;
    b.g = g;
    g.fns.clear();
    g.fns.push({ .f = f, .reg_base = 0 });
    b.overrides.init(mem);
    b.load_reps.init(mem);
    b.sites.init(mem);
    if (!b.analyze()) {
        *refused_op = b.refused_op;
        return b.refused;
    }
    uint n = b.nregs;
    b.cur = mem::new_array(OptRegState, n);
    b.load_def = mem::new_array(uint, n);
    b.const_def = mem::new_array(uint, n);
    b.dead = mem::new_array(bool, b.nrpo);
    b.fact_shape = mem::new_array(uint, (usz)n + 1);
    b.fact_plain = mem::new_array(bool, (usz)n + 1);
    b.fact_elem = mem::new_array(char, (usz)n + 1);
    b.head_shape = mem::new_array(uint, (usz)b.nrpo * ((usz)n + 1));
    b.head_plain = mem::new_array(bool, (usz)b.nrpo * ((usz)n + 1));
    b.head_elem = mem::new_array(char, (usz)b.nrpo * ((usz)n + 1));
    b.head_bindings = mem::new_array(ulong, b.nrpo);
    b.head_captures = mem::new_array(ulong, b.nrpo);
    b.head_set = mem::new_array(bool, b.nrpo);
    b.end_shape = mem::new_array(uint, (usz)b.nrpo * ((usz)n + 1));
    b.end_plain = mem::new_array(bool, (usz)b.nrpo * ((usz)n + 1));
    b.end_elem = mem::new_array(char, (usz)b.nrpo * ((usz)n + 1));
    b.end_bindings = mem::new_array(ulong, b.nrpo);
    b.end_captures = mem::new_array(ulong, b.nrpo);
    b.end_avail = mem::new_array(OptAvail, (usz)b.nrpo * OPT_AVAIL_MAX);
    b.end_avail_n = mem::new_array(char, b.nrpo);
    b.ends = mem::new_array(OptRegState, (usz)b.nrpo * n);
    b.entries = mem::new_array(OptRegState, (usz)b.nrpo * n);
    // A nested site's operands become VALUE nodes over rounds of their own, each request
    // stopping the body around it.
    uint rounds = OPT_BUILD_ROUNDS;
    foreach (&s : b.sites) if (s.depth > 1) rounds += 2;
    if (rounds > OPT_BUILD_ROUNDS_MAX) rounds = OPT_BUILD_ROUNDS_MAX;
    for (uint round = 0; round < rounds; round++) {
        b.loop_facts = round + 2 < rounds;
        if (!b.build_round()) {
            // A refusal that a typed load requested in this round may cause is not final.
            if (b.load_changed && !b.flat_fail) {
                b.load_changed = false;
                b.refused = OptRefuse.NONE;
                continue;
            }
            *refused_op = b.refused_op;
            return b.refused;
        }
        if (b.void_round) {
            b.load_changed = false;
            b.refused = OptRefuse.NONE;
            continue;
        }
        bool again = b.repair();
        again |= b.load_changed;
        b.load_changed = false;
        if (!again) {
            if (!b.compute_edges()) return OptRefuse.REPAIR;
            return OptRefuse.NONE;
        }
    }
    return OptRefuse.REPAIR;
}
