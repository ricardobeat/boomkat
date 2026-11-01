// Optional code-generation facilities. Consumers own semantic guards and
// fallback policy; these declarations mirror the bundled SLJIT API.
module boomkat::jit;

extern fn int sljit_has_cpu_feature(int feature);
extern fn int sljit_cmp_info(int condition);
extern fn ZString sljit_get_platform_name();
extern fn int sljit_emit_op2u(void* compiler, int op, int left, long lw, int right, long rw);
extern fn void* sljit_emit_op2cmpz(void* compiler, int op, int dst, long dw, int left, long lw, int right, long rw);
extern fn int sljit_emit_select(void* compiler, int condition, int dst, int left, long lw, int right_reg);
extern fn int sljit_emit_fselect(void* compiler, int condition, int dst, int left, long lw, int right_reg);
extern fn int sljit_emit_op2_shift(
    void* compiler,
    int op,
    int dst,
    long dw,
    int left,
    long lw,
    int right,
    long rw,
    long shift
);
extern fn void* sljit_emit_const(void* compiler, int op, int dst, long dw, long initial);
extern fn void sljit_set_const(usz address, int op, long value, long executable_offset);
extern fn usz sljit_shim_const_addr(void* constant);
extern fn int sljit_emit_mem(void* compiler, int type, int reg, int operand, long offset);
extern fn int sljit_emit_fmem(void* compiler, int type, int reg, int operand, long offset);
extern fn int sljit_emit_mem_update(void* compiler, int type, int reg, int operand, long offset);
extern fn int sljit_emit_fmem_update(void* compiler, int type, int reg, int operand, long offset);
extern fn int sljit_emit_simd_mov(void* compiler, int type, int vector_reg, int operand, long offset);
extern fn int sljit_emit_simd_replicate(void* compiler, int type, int vector_reg, int operand, long offset);
extern fn int sljit_emit_simd_op2(void* compiler, int type, int dst, int left, int right, long rw);

const int SLJIT_HAS_FPU             = 0;
const int SLJIT_HAS_CLZ             = 3;
const int SLJIT_HAS_CTZ             = 4;
const int SLJIT_HAS_REV             = 5;
const int SLJIT_HAS_ROT             = 6;
const int SLJIT_HAS_CMOV            = 7;
const int SLJIT_HAS_SIMD            = 12;
const int SLJIT_SIMD_REGS_ARE_PAIRS = 13;
const int SLJIT_OVERFLOW            = 10;
const int SLJIT_CARRY               = 12;
const int SLJIT_SET_OVERFLOW        = SLJIT_OVERFLOW << 10;
const int SLJIT_SET_CARRY           = SLJIT_CARRY << 10;
const int SLJIT_CLZ                 = 41;
const int SLJIT_CTZ                 = 42;
const int SLJIT_REV                 = 43;
const int SLJIT_MSHL                = 73;
const int SLJIT_MLSHR               = 75;
const int SLJIT_MASHR               = 77;
const int SLJIT_ROTL                = 78;
const int SLJIT_ROTR                = 79;
const int SLJIT_SHL_IMM             = 1 << 9;
const int SLJIT_MEM_LOAD            = 0;
const int SLJIT_MEM_STORE           = 0x200;
const int SLJIT_MEM_UNALIGNED       = 0x400;
const int SLJIT_MEM_PRE             = 0;
const int SLJIT_MEM_POST            = 0x400;
const int SLJIT_MEM_SUPP            = 0x800;
const int SLJIT_SIMD_LOAD           = 0;
const int SLJIT_SIMD_STORE          = 1;
const int SLJIT_SIMD_FLOAT          = 0x400;
const int SLJIT_SIMD_TEST           = 0x800;
const int SLJIT_SIMD_REG_128        = 4 << 12;
const int SLJIT_SIMD_ELEM_8         = 0 << 18;
const int SLJIT_SIMD_ELEM_32        = 2 << 18;
const int SLJIT_SIMD_ELEM_64        = 3 << 18;
const int SLJIT_SIMD_OP2_AND        = 1;
const int SLJIT_SIMD_OP2_OR         = 2;
const int SLJIT_SIMD_OP2_XOR        = 3;
const int SLJIT_SIMD_OP2_SHUFFLE    = 4;

fn int reg_pair(int first, int second) @inline => first | (second << 8);
// Equivalent to SLJIT_SET(condition) in the bundled header.
fn int set_flags(int condition) @inline => condition << 10;

// Saved and scratch registers share one target register file. Reserving the
// fixed state registers leaves the rest available to generated temporaries;
// SLJIT saves ABI-preserved registers used as additional scratch registers.
fn int scratch_register_count(int saveds) @feat(SLJIT) {
    int total = sljit_shim_info(0);
    int count = total > saveds ? total - saveds : 0;
    // A maximum-size context adds ABI saves to every baseline function.
    // Keep it experimental until context selection follows actual allocation;
    // the wider ARM64 context reduced spills but lost on the timing panel.
    $if !$feat(SLJIT_EXTRA_FUNCTION_SCRATCH) || $feat(SLJIT_NO_EXTRA_FUNCTION_SCRATCH):
        if (count > 7) count = 7;
    $endif
    return count;
}
