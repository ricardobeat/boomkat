/// Minimal copy-patch JIT for arm64 (Apple Silicon).
///
/// Compiles the fastint-only straight-line arithmetic of a compiled function
/// to native code, executed via MAP_JIT. Any opcode outside the supported set,
/// or any runtime non-fastint operand, DEOPTS: the native function returns a
/// sentinel and the interpreter re-executes the whole function from scratch.
/// This is a spike foundation — it proves the emit/execute/deopt pipeline end
/// to end on trivial functions before extending to CALL/branches.
///
/// Gated behind $feature(JIT_ARM64); the default build contains no JIT code.
module duktape::vm;

import duktape::bytecode;
import duktape::types;
import duktape::hstring;
import std::core::mem;

// --- libc / Darwin JIT FFI ---
extern fn void* mmap(void* addr, usz len, int prot, int flags, int fd, long off);
extern fn int munmap(void* addr, usz len);
extern fn void pthread_jit_write_protect_np(int enabled);
extern fn void sys_icache_invalidate(void* start, usz len);

const int PROT_READ  = 0x1;
const int PROT_WRITE = 0x2;
const int PROT_EXEC  = 0x4;
const int MAP_PRIVATE = 0x2;
const int MAP_ANON    = 0x1000;
const int MAP_JIT     = 0x800;

/// Allocate an executable MAP_JIT page (Apple Silicon, no entitlements).
/// Returns null on failure. `words` is the capacity in 32-bit instructions.
fn uint* jit_alloc_page(uint words) {
    usz bytes = (usz)words * 4;
    if (bytes < 4096) { bytes = 4096; }
    void* p = mmap(null, bytes, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p == null || (long)p == -1) { return null; }
    return (uint*)p;
}

/// Finalize an emitted buffer: flip W^X to executable and flush icache.
fn void jit_finalize(JitBuf* b) {
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate((void*)b.code, (usz)b.pos * 4);
}

/// Enter write mode before emitting into a MAP_JIT page.
fn void jit_begin_write() {
    pthread_jit_write_protect_np(0);
}

// A JIT'd function takes a pointer to the register file (TVal[]) and returns
// the result TVal bits, OR the DEOPT sentinel to signal "bail to interpreter".
alias JitFn = fn ulong(TVal* regs);

// Deopt sentinel: a NaN-boxed value that can never be a legitimate result.
// We use an all-ones payload with a reserved tag the VM never produces.
const ulong JIT_DEOPT = 0xFFFEDEAD_DEADBEEF;

/// Emitted-code buffer + write cursor.
struct JitBuf {
    uint* code;      // MAP_JIT executable page
    uint  pos;       // instruction slot cursor
    uint  cap;       // capacity in 32-bit words
    bool  failed;    // codegen bailed (unsupported shape)
}

fn void JitBuf.emit(&self, uint insn) {
    if (self.pos >= self.cap) { self.failed = true; return; }
    self.code[self.pos] = insn;
    self.pos++;
}

// --- arm64 instruction encoders (only what we need) ---
// x0 = regs pointer (arg0), x1..x15 scratch.

// LDR Xt, [Xn, #imm] (imm scaled by 8, unsigned) — load 8-byte TVal.bits
fn uint enc_ldr(uint t, uint n, uint imm_bytes) {
    uint imm12 = (imm_bytes / 8) & 0xFFF;
    return 0xF9400000u | (imm12 << 10) | (n << 5) | t;
}
// STR Xt, [Xn, #imm]
fn uint enc_str(uint t, uint n, uint imm_bytes) {
    uint imm12 = (imm_bytes / 8) & 0xFFF;
    return 0xF9000000u | (imm12 << 10) | (n << 5) | t;
}
// MOVZ Xd, #imm16, LSL #(shift*16)
fn uint enc_movz(uint d, uint imm16, uint shift) {
    return 0xD2800000u | (shift << 21) | ((imm16 & 0xFFFF) << 5) | d;
}
// MOVK Xd, #imm16, LSL #(shift*16)
fn uint enc_movk(uint d, uint imm16, uint shift) {
    return 0xF2800000u | (shift << 21) | ((imm16 & 0xFFFF) << 5) | d;
}
// ADD Xd, Xn, Xm
fn uint enc_add(uint d, uint n, uint m) {
    return 0x8B000000u | (m << 16) | (n << 5) | d;
}
// SUB Xd, Xn, Xm
fn uint enc_sub(uint d, uint n, uint m) {
    return 0xCB000000u | (m << 16) | (n << 5) | d;
}
// RET
fn uint enc_ret() { return 0xD65F03C0u; }

/// Load a full 64-bit immediate into Xd via MOVZ + 3×MOVK.
fn void JitBuf.mov_imm64(&self, uint d, ulong v) {
    self.emit(enc_movz(d, (uint)(v & 0xFFFF), 0));
    self.emit(enc_movk(d, (uint)((v >> 16) & 0xFFFF), 1));
    self.emit(enc_movk(d, (uint)((v >> 32) & 0xFFFF), 2));
    self.emit(enc_movk(d, (uint)((v >> 48) & 0xFFFF), 3));
}

// AND Xd, Xn, Xm  (mask NaN-box payload)
fn uint enc_and(uint d, uint n, uint m) {
    return 0x8A000000u | (m << 16) | (n << 5) | d;
}
// ORR Xd, Xn, Xm  (re-tag)
fn uint enc_orr(uint d, uint n, uint m) {
    return 0xAA000000u | (m << 16) | (n << 5) | d;
}
// MOV Xd, Xn  (alias of ORR Xd, XZR, Xn — reg 31 = XZR here)
fn uint enc_mov(uint d, uint n) {
    return 0xAA0003E0u | (n << 16) | d;
}
// MOVN Xd, #imm16, LSL #(shift*16)  (Xd = ~(imm16 << shift*16); for negative imms)
fn uint enc_movn(uint d, uint imm16, uint shift) {
    return 0x92800000u | (shift << 21) | ((imm16 & 0xFFFF) << 5) | d;
}
// STP Xt1, Xt2, [SP, #imm]!  (pre-index, imm scaled by 8, signed 7-bit)
fn uint enc_stp_pre(uint t1, uint t2, int imm_bytes) {
    uint imm7 = ((uint)(imm_bytes / 8)) & 0x7F;
    return 0xA9800000u | (imm7 << 15) | (t2 << 10) | (31u << 5) | t1;
}
// LDP Xt1, Xt2, [SP], #imm  (post-index, imm scaled by 8, signed 7-bit)
fn uint enc_ldp_post(uint t1, uint t2, int imm_bytes) {
    uint imm7 = ((uint)(imm_bytes / 8)) & 0x7F;
    return 0xA8C00000u | (imm7 << 15) | (t2 << 10) | (31u << 5) | t1;
}
// STR Xt, [SP, #imm]  (SP-relative, imm scaled by 8, unsigned)
fn uint enc_str_sp(uint t, uint imm_bytes) {
    uint imm12 = (imm_bytes / 8) & 0xFFF;
    return 0xF9000000u | (imm12 << 10) | (31u << 5) | t;
}
// LDR Xt, [SP, #imm]  (SP-relative)
fn uint enc_ldr_sp(uint t, uint imm_bytes) {
    uint imm12 = (imm_bytes / 8) & 0xFFF;
    return 0xF9400000u | (imm12 << 10) | (31u << 5) | t;
}
// BLR Xn  (branch with link to register)
fn uint enc_blr(uint n) {
    return 0xD63F0000u | (n << 5);
}
// LSL Xd, Xn, #sh  (alias of UBFM; here we only need the shift-left form)
fn uint enc_lsl_imm(uint d, uint n, uint sh) {
    uint immr = ((64u - sh) & 63u);
    uint imms = (63u - sh);
    return 0xD3400000u | (immr << 16) | (imms << 10) | (n << 5) | d;
}
// ASR Xd, Xn, #sh  (alias of SBFM Xd,Xn,#sh,#63 — arithmetic shift right)
fn uint enc_asr_imm(uint d, uint n, uint sh) {
    return 0x9340FC00u | ((sh & 63u) << 16) | (n << 5) | d;
}
// LSR Xd, Xn, #sh  (alias of UBFM Xd,Xn,#sh,#63 — logical shift right)
fn uint enc_lsr_imm(uint d, uint n, uint sh) {
    return 0xD340FC00u | ((sh & 63u) << 16) | (n << 5) | d;
}
// CMP Xn, Xm  (alias of SUBS XZR, Xn, Xm — sets NZCV flags)
fn uint enc_cmp(uint n, uint m) {
    return 0xEB00001Fu | (m << 16) | (n << 5);
}
// B.cond <offset>  (offset in instructions, signed 19-bit, relative to this insn)
fn uint enc_bcond(uint cond, int off_insns) {
    uint imm19 = ((uint)off_insns) & 0x7FFFF;
    return 0x54000000u | (imm19 << 5) | (cond & 0xF);
}
// B <offset>  (unconditional, signed 26-bit, relative to this insn)
fn uint enc_b(int off_insns) {
    uint imm26 = ((uint)off_insns) & 0x3FFFFFF;
    return 0x14000000u | imm26;
}
// BL <offset>  (branch with link, signed 26-bit, relative to this insn)
fn uint enc_bl(int off_insns) {
    uint imm26 = ((uint)off_insns) & 0x3FFFFFF;
    return 0x94000000u | imm26;
}
// ADD Xd, Xn, #imm12  (immediate, unsigned)
fn uint enc_add_imm(uint d, uint n, uint imm12) {
    return 0x91000000u | ((imm12 & 0xFFF) << 10) | (n << 5) | d;
}
// SUB Xd, Xn, #imm12  (immediate, unsigned)
fn uint enc_sub_imm(uint d, uint n, uint imm12) {
    return 0xD1000000u | ((imm12 & 0xFFF) << 10) | (n << 5) | d;
}
// Condition codes.
const uint COND_EQ = 0x0;
const uint COND_NE = 0x1;
const uint COND_GT = 0xC;   // signed greater than
const uint COND_LE = 0xD;   // signed less than or equal
const uint COND_LT = 0xB;   // signed less than
const uint COND_GE = 0xA;   // signed greater than or equal

/// SELF-TEST: emit a native fn returning fastint(payload(reg[i]) +
/// payload(reg[j])) re-tagged as fastint. Proves emit -> MAP_JIT execute ->
/// correct fastint arithmetic end to end, validating the JIT core before the
/// full bytecode compile loop + deopt are wired. Returns raw TVal bits, or 0
/// on alloc/emit failure.
fn ulong jit_selftest_add(TVal* regs, uint i, uint j) {
    JitBuf b;
    b.code = jit_alloc_page(64);
    if (b.code == null) { return 0; }
    b.pos = 0; b.cap = 64; b.failed = false;

    jit_begin_write();
    b.emit(enc_ldr(1, 0, i * 8));                    // x1 = reg[i].bits
    b.emit(enc_ldr(2, 0, j * 8));                    // x2 = reg[j].bits
    b.mov_imm64(3, types::NANBOX_PAYLOAD_MASK);      // x3 = payload mask
    b.emit(enc_and(1, 1, 3));                        // x1 = payload(reg[i])
    b.emit(enc_and(2, 2, 3));                        // x2 = payload(reg[j])
    b.emit(enc_add(1, 1, 2));                        // x1 = sum
    b.emit(enc_and(1, 1, 3));                        // wrap to 48-bit payload
    b.mov_imm64(2, types::TAG_FASTINT << 48);        // x2 = fastint tag
    b.emit(enc_orr(0, 1, 2));                        // x0 = tagged result
    b.emit(enc_ret());
    if (b.failed) { munmap((void*)b.code, 4096); return 0; }
    jit_finalize(&b);

    JitFn f = bitcast((uptr)(void*)b.code, JitFn);
    ulong result = f(regs);
    munmap((void*)b.code, 4096);
    return result;
}

// Native signature for the call round-trip selftest below.
alias JitCallFn = fn ulong(void* vm, ulong func_bits, TVal* args);

/// SELF-TEST: emit a native fn that invokes `vm_call_fn_impl(vm, func, args, 1,
/// undefined)` and returns the callee's result TVal bits. Proves the JIT->C
/// call ABI end to end — arm64 prologue/epilogue (fp/lr save), AAPCS64 arg
/// marshalling (x0=vm, x1=func.bits by value, x2=args, w3=nargs, x4=this.bits),
/// BLR through a materialized function-pointer address, and the 8-byte struct
/// return in x0 — WITHOUT yet emitting the full fib body. This is the hard core
/// the recursive JIT needs; verifying it in isolation catches any
/// frame/register/ABI error before it can corrupt the heap inside a real call.
/// Returns the callee result bits, or 0 on alloc/emit failure.
fn ulong jit_selftest_call(void* vm, ulong func_bits, TVal* args) {
    JitBuf b;
    b.code = jit_alloc_page(64);
    if (b.code == null) { return 0; }
    b.pos = 0; b.cap = 64; b.failed = false;

    // Address of the C call entry, materialized as a 64-bit immediate.
    ulong callee_addr = (ulong)(uptr)(void*)&vm_call_fn_impl;
    // Undefined TVal bits (tag TAG_UNDEFINED, zero payload).
    TVal undef; undef.set_undefined();

    jit_begin_write();
    // Prologue: save fp(x29)/lr(x30), open a 16-byte frame.
    b.emit(enc_stp_pre(29, 30, -16));
    // Args are already in x0(vm), x1(func_bits), x2(args) per JitCallFn's own
    // AAPCS64 mapping — which matches vm_call_fn_impl's first three params
    // (void* vm, TVal func, TVal* args) exactly. Set the remaining two:
    b.emit(enc_movz(3, 1, 0));                        // w3 = nargs = 1
    b.mov_imm64(4, undef.bits);                       // x4 = this = undefined
    b.mov_imm64(9, callee_addr);                      // x9 = &vm_call_fn_impl
    b.emit(enc_blr(9));                               // call; result TVal in x0
    // Epilogue: restore fp/lr, return (result already in x0).
    b.emit(enc_ldp_post(29, 30, 16));
    b.emit(enc_ret());
    if (b.failed) { munmap((void*)b.code, 4096); return 0; }
    jit_finalize(&b);

    JitCallFn f = bitcast((uptr)(void*)b.code, JitCallFn);
    ulong result = f(vm, func_bits, args);
    munmap((void*)b.code, 4096);
    return result;
}

// ============================================================================
// Minimal fastint-body compiler
// ============================================================================
//
// Compiles the straight-line fastint arithmetic + branches + self-recursive
// CALL of a compiled function to native arm64. This is deliberately small and
// portable in shape: the compile loop below speaks in semantic steps (load a
// register, sign-extend a fastint, deopt if a value is not a fastint, call the
// C entry, branch), each backed by a handful of arm64 encoders. A second
// backend (x86-64) would reimplement only those encoders + the tiny emit
// helpers, not the compile loop.
//
// Register convention inside a JIT'd body (all callee-saved, preserved across
// the BLR to vm_call_fn_impl):
//   x19 = vm            x20 = regs (TVal*)      x21 = self func bits
//   x22 = payload mask  x23 = fastint tag<<48
// Scratch (caller-saved): x0..x9.
//
// The JIT'd body's own AAPCS64 signature (see JitBodyFn) is
//   ulong body(void* vm, TVal* regs, ulong self_func_bits)
// so on entry x0=vm, x1=regs, x2=self_func_bits. It returns the result TVal
// bits, or JIT_DEOPT to ask the caller to re-run on the interpreter.

alias JitBodyFn = fn ulong(void* vm, TVal* regs, ulong self_func_bits);

/// A compiled body plus the page it lives on (so it can be freed).
struct JitCode {
    JitBodyFn body;
    uint*     page;
    usz       page_bytes;
}

// Per-bytecode-pc native offset table + pending branch fixups.
struct JitFixup {
    uint  native_pos;   // index of the branch instruction in the code buffer
    uint  target_pc;    // bytecode pc it jumps to
    uint  cond;         // condition code, or 0xFF for unconditional B
}

const uint JIT_MAX_CODE = 4096;   // 32-bit words per body page (16 KiB)

/// Emit: load regs[r].bits into Xd (scratch). regs base is x20.
fn void JitBuf.ld_reg(&self, uint d, uint r) {
    // LDR Xd, [x20, #r*8]
    self.emit(enc_ldr(d, 20, r * 8));
}
/// Emit: store Xs.bits into regs[r]. regs base is x20.
fn void JitBuf.st_reg(&self, uint s, uint r) {
    self.emit(enc_str(s, 20, r * 8));
}
/// Emit: Xd = sign-extended 48-bit fastint payload of the value in Xn.
/// (payload = Xn & mask; then (payload << 16) >> 16 arithmetic.)
fn void JitBuf.sext_fastint(&self, uint d, uint n) {
    self.emit(enc_and(d, n, 22));       // d = n & payload_mask
    self.emit(enc_lsl_imm(d, d, 16));   // d <<= 16
    self.emit(enc_asr_imm(d, d, 16));   // d >>= 16 (arithmetic)
}
/// Emit: Xd = fastint-tagged TVal bits for the (already-in-range) integer Xn.
/// bits = (Xn & payload_mask) | (TAG_FASTINT << 48).
fn void JitBuf.retag_fastint(&self, uint d, uint n) {
    self.emit(enc_and(d, n, 22));       // d = n & payload_mask
    self.emit(enc_orr(d, d, 23));       // d |= tag
}
/// Emit a deopt guard: if regs[r] is not a fastint, jump to the deopt epilogue.
/// Uses x8/x9 as scratch. The branch is recorded as a fixup with target_pc =
/// DEOPT_PC and patched to the shared deopt epilogue at the end.
const uint DEOPT_PC = 0xFFFFFFFFu;
// Special fixup targets/conditions for non-conditional branches.
const uint BODY_ENTRY_PC = 0xFFFFFFFEu;   // target = native pc 0 (body prologue)
const uint COND_BL = 0xFEu;               // fixup emits BL, not B.cond
fn void JitBuf.guard_fastint(&self, uint r, JitFixup[] fixups, uint* nfix) {
    self.ld_reg(8, r);
    self.emit(enc_lsr_imm(8, 8, 48));           // x8 = tag
    self.mov_imm64(9, types::TAG_FASTINT);
    self.emit(enc_cmp(8, 9));                    // flags = tag - TAG_FASTINT
    if (*nfix < fixups.len) {
        fixups[*nfix] = { .native_pos = self.pos, .target_pc = DEOPT_PC, .cond = COND_NE };
        (*nfix)++;
    }
    self.emit(enc_bcond(COND_NE, 0));            // B.NE deopt (patched later)
}

/// Try to compile `target`'s body to native arm64. Returns a JitCode with a
/// non-null fn on success, or {} (fn == null) if the body contains any opcode
/// or shape outside the supported fastint/self-recursion set — the caller then
/// stays on the interpreter. Only self-recursive CALL_VAR (callee == this same
/// function) is supported; any other callee bails.
fn JitCode jit_compile(CompiledFunction* target) {
    JitCode none = {};
    if (target == null || target.code == null) return none;
    uint n = target.code_count;
    if (n == 0 || n > 512) return none;

    // native_pc[i] = code-buffer index where bytecode instruction i begins.
    uint[512] native_pc;
    JitFixup[512] fixups;
    uint nfix = 0;

    uint* page = jit_alloc_page(JIT_MAX_CODE);
    if (page == null) return none;
    JitBuf b;
    b.code = page; b.pos = 0; b.cap = JIT_MAX_CODE; b.failed = false;

    jit_begin_write();

    // --- Prologue ---
    // Save fp/lr and the five callee-saved regs we use (x19..x23), in a 64-byte
    // frame. Slots at SP offsets 0,8 hold fp/lr; 16,24,32,40,48 hold x19..x23.
    b.emit(enc_stp_pre(29, 30, -64));
    b.emit(enc_str_sp(19, 16));
    b.emit(enc_str_sp(20, 24));
    b.emit(enc_str_sp(21, 32));
    b.emit(enc_str_sp(22, 40));
    b.emit(enc_str_sp(23, 48));
    // Move incoming args into callee-saved homes: x0=vm, x1=regs, x2=self bits.
    b.emit(enc_mov(19, 0));                          // x19 = vm
    b.emit(enc_mov(20, 1));                          // x20 = regs
    b.emit(enc_mov(21, 2));                          // x21 = self func bits
    b.mov_imm64(22, types::NANBOX_PAYLOAD_MASK);     // x22 = payload mask
    b.mov_imm64(23, types::TAG_FASTINT << 48);       // x23 = fastint tag<<48
    // The lean self-recursion entry, plus this function's own CompiledFunction*
    // (a compile-time constant) that jit_recurse needs to re-enter the body.
    ulong recurse_addr = (ulong)(uptr)(void*)&jit_recurse;
    ulong target_ptr = (ulong)(uptr)(void*)target;

    // --- Body ---
    for (uint pc = 0; pc < n; pc++) {
        native_pc[pc] = b.pos;
        Instruction insn = target.code[pc];
        Opcode op = insn.op;
        uint a = insn.a;
        uint bb = insn.b;
        uint c = insn.c;
        switch (op) {
            case Opcode.LDINT: {
                // A = (int)sBx  — signed 16-bit immediate (B low, C high).
                short sbx = (short)(ushort)(bb | (c << 8));
                long imm = (long)sbx;
                b.mov_imm64(0, (ulong)imm);           // x0 = imm (sign in bits)
                b.retag_fastint(1, 0);                // x1 = fastint(imm)
                b.st_reg(1, a);
            }
            case Opcode.SUBI: {
                // A = B - (signed8)C  (fastint fast path; deopt otherwise).
                b.guard_fastint(bb, fixups[..], &nfix);
                b.ld_reg(0, bb);
                b.sext_fastint(0, 0);                 // x0 = sext(regs[B])
                long imm = (long)(ichar)c;
                b.mov_imm64(1, (ulong)imm);
                b.emit(enc_sub(0, 0, 1));             // x0 = B - imm
                b.retag_fastint(2, 0);
                b.st_reg(2, a);
            }
            case Opcode.ADD: {
                // A = B + C  (fastint fast path; deopt otherwise).
                b.guard_fastint(bb, fixups[..], &nfix);
                b.guard_fastint(c, fixups[..], &nfix);
                b.ld_reg(0, bb); b.sext_fastint(0, 0);
                b.ld_reg(1, c);  b.sext_fastint(1, 1);
                b.emit(enc_add(0, 0, 1));
                b.retag_fastint(2, 0);
                b.st_reg(2, a);
            }
            case Opcode.SUB: {
                b.guard_fastint(bb, fixups[..], &nfix);
                b.guard_fastint(c, fixups[..], &nfix);
                b.ld_reg(0, bb); b.sext_fastint(0, 0);
                b.ld_reg(1, c);  b.sext_fastint(1, 1);
                b.emit(enc_sub(0, 0, 1));
                b.retag_fastint(2, 0);
                b.st_reg(2, a);
            }
            case Opcode.JMP_NLE: {
                // if !(regs[B] <= regs[C]) goto pc+1+offset ; offset = (int8)A.
                // Both operands must be fastint or we deopt (interpreter handles
                // the general <= including NaN/coercion).
                b.guard_fastint(bb, fixups[..], &nfix);
                b.guard_fastint(c, fixups[..], &nfix);
                b.ld_reg(0, bb); b.sext_fastint(0, 0);
                b.ld_reg(1, c);  b.sext_fastint(1, 1);
                b.emit(enc_cmp(0, 1));                // flags = B - C
                // Branch when NOT (B <= C), i.e. B > C  => COND_GT.
                int off = (int)(ichar)a;
                uint tgt = pc + 1 + (uint)off;
                if (nfix < 512) {
                    fixups[nfix] = { .native_pos = b.pos, .target_pc = tgt, .cond = COND_GT };
                    nfix++;
                }
                b.emit(enc_bcond(COND_GT, 0));
            }
            case Opcode.RET: {
                // return regs[A].bits
                b.ld_reg(0, a);
                // Epilogue.
                b.emit(enc_ldr_sp(19, 16));
                b.emit(enc_ldr_sp(20, 24));
                b.emit(enc_ldr_sp(21, 32));
                b.emit(enc_ldr_sp(22, 40));
                b.emit(enc_ldr_sp(23, 48));
                b.emit(enc_ldp_post(29, 30, 64));
                b.emit(enc_ret());
            }
            case Opcode.CALL_VAR: {
                // Self-recursive call, kept fully native: instead of a C
                // round-trip, allocate the callee's register window on the
                // native stack, copy the (already fastint) args into it, and
                // BL directly to this body's own entry (body_entry). The callee
                // may DEOPT — its return is checked against JIT_DEOPT and, on
                // deopt, we fall back to jit_recurse (which re-runs the callee
                // on the interpreter and returns the correct result), so
                // correctness is preserved.
                //
                // Args live at regs[A+2 .. A+1+nargs] (frame_start = A+2);
                // the callee reads them from window[0..nargs-1].
                uint nargs = bb;
                // Window: num_regs TVal slots, rounded up to a 16-byte multiple.
                uint win_slots = target.num_regs;
                uint win_bytes = ((win_slots * 8) + 15) & ~15u;
                b.emit(enc_sub_imm(31, 31, win_bytes));   // SUB sp, sp, #win_bytes
                // Copy args from caller regs[A+2+i] to window[i].
                for (uint i = 0; i < nargs; i++) {
                    b.ld_reg(0, a + 2 + i);               // x0 = regs[A+2+i]
                    b.emit(enc_str_sp(0, i * 8));         // window[i] = x0
                }
                // x0=vm, x1=window(sp), x2=self bits, then BL body_entry.
                b.emit(enc_mov(0, 19));
                b.emit(enc_mov(2, 21));
                b.emit(enc_add_imm(1, 31, 0));            // MOV x1, sp (ADD x1, sp, #0)
                // BL to body_entry (patched: it's a forward/back ref to a known
                // native pc). Record as an unconditional-call fixup.
                if (nfix < 512) {
                    fixups[nfix] = { .native_pos = b.pos, .target_pc = BODY_ENTRY_PC, .cond = COND_BL };
                    nfix++;
                }
                b.emit(enc_bl(0));                        // placeholder
                b.emit(enc_add_imm(31, 31, win_bytes));   // release window
                // Deopt check: if result == JIT_DEOPT, take the slow path.
                b.mov_imm64(1, JIT_DEOPT);
                b.emit(enc_cmp(0, 1));
                // B.NE past the slow path.
                uint skip_pos = b.pos;
                b.emit(enc_bcond(COND_NE, 0));            // patched below
                // Slow path: jit_recurse(vm, target, self_bits, &regs[A+2], nargs).
                b.emit(enc_mov(0, 19));
                b.mov_imm64(1, target_ptr);
                b.emit(enc_mov(2, 21));
                b.emit(enc_add_imm(3, 20, (a + 2) * 8));
                b.emit(enc_movz(4, nargs, 0));
                b.mov_imm64(9, recurse_addr);
                b.emit(enc_blr(9));                       // result in x0
                // Patch the B.NE to skip to here (the store below).
                {
                    int rel = (int)b.pos - (int)skip_pos;
                    b.code[skip_pos] = enc_bcond(COND_NE, rel);
                }
                b.st_reg(0, a);                           // regs[A] = result
            }
            default: {
                // Unsupported opcode — bail out, free page, stay on interpreter.
                b.failed = true;
            }
        }
        if (b.failed) { munmap((void*)page, (usz)JIT_MAX_CODE * 4); return none; }
    }

    // --- Shared deopt epilogue: restore callee-saved regs, return JIT_DEOPT ---
    uint deopt_pos = b.pos;
    b.mov_imm64(0, JIT_DEOPT);
    b.emit(enc_ldr_sp(19, 16));
    b.emit(enc_ldr_sp(20, 24));
    b.emit(enc_ldr_sp(21, 32));
    b.emit(enc_ldr_sp(22, 40));
    b.emit(enc_ldr_sp(23, 48));
    b.emit(enc_ldp_post(29, 30, 64));
    b.emit(enc_ret());

    if (b.failed) { munmap((void*)page, (usz)JIT_MAX_CODE * 4); return none; }

    // --- Patch branch fixups ---
    for (uint i = 0; i < nfix; i++) {
        JitFixup fx = fixups[i];
        uint dst;
        if (fx.target_pc == DEOPT_PC) { dst = deopt_pos; }
        else if (fx.target_pc == BODY_ENTRY_PC) { dst = 0; }   // body prologue
        else { dst = native_pc[fx.target_pc]; }
        int rel = (int)dst - (int)fx.native_pos;   // in instructions
        if (fx.cond == COND_BL) { page[fx.native_pos] = enc_bl(rel); }
        else { page[fx.native_pos] = enc_bcond(fx.cond, rel); }
    }

    jit_finalize(&b);
    JitCode out;
    out.body = bitcast((uptr)(void*)page, JitBodyFn);
    out.page = page;
    out.page_bytes = (usz)JIT_MAX_CODE * 4;
    return out;
}

// Runtime master switch for the JIT. Off by default; the CLI / a future
// heuristic flips it on. Keeping it a plain global (not a $feature) means the
// wiring is exercised by the normal build and can be toggled without a rebuild.
bool jit_enabled = false;

/// Lean self-recursion entry the JIT'd body calls for CALL_VAR (instead of the
/// heavyweight vm_call_fn_impl). Because the callee is THIS function (verified
/// self-recursive at compile time), we go straight to the native body via
/// try_jit_call, keeping the recursion native→native with no interpreter
/// dispatch. Only a genuine deopt (a non-fastint argument, or a runtime bail)
/// falls back to the full call path. Args are at `argbase[0..nargs-1]`; returns
/// the result TVal bits.
fn ulong jit_recurse(Vm* vm, CompiledFunction* target, ulong func_bits,
                     TVal* argbase, uint nargs) {
    // Hot path: the body is already compiled (jit_status==1 guaranteed, since
    // this entry only exists in a compiled body). Re-enter native directly,
    // inlining the tiny register-file setup to avoid a second call frame.
    if (target.jit_status == 1) {
        uint na = target.num_args;
        // Fast fastint-arg check + register setup fused. Bail on non-fastint.
        bool all_fi = nargs <= na;
        for (uint i = 0; all_fi && i < nargs; i++) {
            if (!argbase[i].is_fastint()) { all_fi = false; }
        }
        if (all_fi) {
            uint nregs = target.num_regs;
            TVal[64] regs;
            for (uint i = 0; i < nregs; i++) {
                regs[i] = i < nargs ? argbase[i] : (TVal){ .bits = types::TAG_UNDEFINED << 48 };
            }
            JitBodyFn body = bitcast((uptr)target.jit_body, JitBodyFn);
            ulong r = body((void*)vm, &regs[0], func_bits);
            if (r != JIT_DEOPT) { return r; }
        }
    }
    // Deopt / non-fastint: fall back to the full interpreter call path.
    TVal func; func.bits = func_bits;
    TVal undef; undef.set_undefined();
    TVal ir = vm_call_fn_impl((void*)vm, func, argbase, nargs, undef);
    return ir.bits;
}

/// Return true if `target`'s body is within the JIT's supported subset:
/// only fastint arithmetic + JMP_NLE + RET + self-recursive CALL_VAR, and every
/// CALL_VAR must resolve to THIS function by name (so the body's hardcoded
/// self-call is sound). Anything else → not jittable.
fn bool jit_is_jittable(CompiledFunction* target) {
    if (target == null || target.code == null) return false;
    if (target.code_count == 0 || target.code_count > 512) return false;
    if (target.num_regs > 60) return false;   // register file cap (see try_jit_call)
    char[] self_name = target.get_name();
    if (self_name.len == 0) return false;      // need a name to verify self-calls
    for (uint pc = 0; pc < target.code_count; pc++) {
        Instruction insn = target.code[pc];
        switch (insn.op) {
            case Opcode.LDINT:
            case Opcode.SUBI:
            case Opcode.ADD:
            case Opcode.SUB:
            case Opcode.JMP_NLE:
            case Opcode.RET:
                break;
            case Opcode.CALL_VAR: {
                // Verify constants[C] is a string equal to the function's own
                // name — otherwise the JIT'd body would call the wrong callee.
                uint ci = insn.c;
                if (ci >= target.const_count) return false;
                TVal name_tv = target.constants[ci];
                if (!name_tv.is_string()) return false;
                HString* nh = (HString*)name_tv.get_heapptr();
                if (nh == null) return false;
                char[] cd = nh.get_data();
                if (cd.len != self_name.len) return false;
                for (usz k = 0; k < cd.len; k++) {
                    if (cd[k] != self_name[k]) return false;
                }
            }
            default:
                return false;
        }
    }
    return true;
}

/// Attempt to run `target` natively for a call with `nargs` args. Returns true
/// (with *out set) if the JIT handled the call to completion; false if the call
/// must fall back to the interpreter (not jittable, args not all fastint, or a
/// runtime deopt). Lazily compiles + caches the body on first eligible call.
fn bool try_jit_call(Vm* vm, CompiledFunction* target, TVal func,
                     TVal* args, uint nargs, TVal* out) {
    // Status: 0 = untried, 1 = compiled, 2 = unsupported.
    if (target.jit_status == 2) return false;
    if (target.jit_status == 0) {
        if (!jit_is_jittable(target)) { target.jit_status = 2; return false; }
        JitCode jc = jit_compile(target);
        if (jc.body == null) { target.jit_status = 2; return false; }
        target.jit_body = (void*)jc.body;
        target.jit_status = 1;
    }
    if (target.jit_body == null) return false;
    // All args must be fastint (the body's arithmetic assumes it; non-fastint
    // args would hit a deopt guard immediately — cheaper to check here).
    if (nargs > target.num_args) return false;
    for (uint i = 0; i < nargs; i++) {
        if (!args[i].is_fastint()) return false;
    }
    // Register file: args in regs[0..nargs-1], the rest undefined.
    TVal[64] regs;
    uint nregs = target.num_regs;
    for (uint i = 0; i < nregs; i++) {
        if (i < nargs) { regs[i] = args[i]; }
        else { regs[i].set_undefined(); }
    }
    JitBodyFn body = bitcast((uptr)target.jit_body, JitBodyFn);
    ulong r = body((void*)vm, &regs[0], func.bits);
    if (r == JIT_DEOPT) return false;
    out.bits = r;
    return true;
}

