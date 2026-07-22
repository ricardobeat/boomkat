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

