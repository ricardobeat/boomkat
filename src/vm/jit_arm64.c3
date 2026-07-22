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
import std::core::mem;


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

