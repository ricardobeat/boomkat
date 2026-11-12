#include "sljitLir.h"

/* This SLJIT revision has ABS_F64 but no SQRT_F64. Emit an IEEE sqrt
 * instruction, using SLJIT's actual floating-register mapping. */
int sljit_shim_sqrt_f64(struct sljit_compiler *compiler, int freg)
{
#if (defined SLJIT_CONFIG_X86_64 && SLJIT_CONFIG_X86_64)
    int r = sljit_get_register_index(SLJIT_FLOAT_REGISTER, freg);
    unsigned char op[5];
    unsigned n = 0;
    if (r < 0 || r > 15) return -1;
    op[n++] = 0xf2;
    if (r >= 8) op[n++] = 0x45; /* REX.R | REX.B */
    op[n++] = 0x0f;
    op[n++] = 0x51; /* SQRTSD xmm, xmm */
    op[n++] = (unsigned char)(0xc0 | ((r & 7) << 3) | (r & 7));
    return sljit_emit_op_custom(compiler, op, n);
#elif (defined SLJIT_CONFIG_ARM_64 && SLJIT_CONFIG_ARM_64)
    int r = sljit_get_register_index(SLJIT_FLOAT_REGISTER, freg);
    sljit_u32 op;
    if (r < 0 || r > 31) return -1;
    op = 0x1e61c000u | ((sljit_u32)r << 5) | (sljit_u32)r; /* FSQRT Dd,Dn */
    return sljit_emit_op_custom(compiler, &op, sizeof(op));
#else
    (void)compiler; (void)freg;
    return -1;
#endif
}


/* Round `freg` in place toward -inf (down != 0) or +inf: FRINTM and FRINTP. Other targets have no
 * instruction here and return -1, as the C fallback is then the caller's. */
int sljit_shim_round_f64(struct sljit_compiler *compiler, int freg, int down)
{
#if (defined SLJIT_CONFIG_ARM_64 && SLJIT_CONFIG_ARM_64)
    int r = sljit_get_register_index(SLJIT_FLOAT_REGISTER, freg);
    sljit_u32 op;
    if (r < 0 || r > 31) return -1;
    op = (down ? 0x1e654000u : 0x1e64c000u) | ((sljit_u32)r << 5) | (sljit_u32)r;
    return sljit_emit_op_custom(compiler, &op, sizeof(op));
#else
    (void)compiler; (void)freg; (void)down;
    return -1;
#endif
}

/* Move the stack pointer by `delta` bytes (a multiple of 16 below 4096 in magnitude): the native
 * frame of a register-mode call, which SLJIT's model of one frame per function cannot express.
 * Other targets return -1 and have no register-mode calls. */
int sljit_shim_adjust_sp(struct sljit_compiler *compiler, int delta)
{
    unsigned magnitude = (unsigned)(delta < 0 ? -delta : delta);
    if ((magnitude & 15) != 0 || magnitude >= 4096) return -1;
#if (defined SLJIT_CONFIG_X86_64 && SLJIT_CONFIG_X86_64)
    /* SUB/ADD RSP, imm32 */
    unsigned char op[7] = { 0x48, 0x81, delta < 0 ? 0xec : 0xc4, 0, 0, 0, 0 };
    op[3] = (unsigned char)magnitude;
    op[4] = (unsigned char)(magnitude >> 8);
    return sljit_emit_op_custom(compiler, op, sizeof(op));
#elif (defined SLJIT_CONFIG_ARM_64 && SLJIT_CONFIG_ARM_64)
    /* SUB/ADD SP, SP, #imm12 */
    sljit_u32 op = (delta < 0 ? 0xd1000000u : 0x91000000u) | (magnitude << 10) | (31u << 5) | 31u;
    return sljit_emit_op_custom(compiler, &op, sizeof(op));
#else
    (void)compiler;
    return -1;
#endif
}

/* Copy the stack pointer into general register `reg` (to_sp == 0), or `reg` into the stack pointer:
 * the stack of an entry from C, which every way out of generated code returns to, whatever native
 * frames of register-mode calls lie below it. Other targets return -1. */
int sljit_shim_move_sp(struct sljit_compiler *compiler, int reg, int to_sp)
{
#if (defined SLJIT_CONFIG_X86_64 && SLJIT_CONFIG_X86_64)
    int r = sljit_get_register_index(SLJIT_GP_REGISTER, reg);
    unsigned char op[3];
    if (r < 0 || r > 15) return -1;
    /* MOV r/m64, r64: MOV RSP, r (to_sp) or MOV r, RSP. */
    if (to_sp) {
        op[0] = (unsigned char)(0x48 | (r >= 8 ? 0x04 : 0));
        op[2] = (unsigned char)(0xc0 | ((r & 7) << 3) | 4);
    } else {
        op[0] = (unsigned char)(0x48 | (r >= 8 ? 0x01 : 0));
        op[2] = (unsigned char)(0xc0 | (4 << 3) | (r & 7));
    }
    op[1] = 0x89;
    return sljit_emit_op_custom(compiler, op, sizeof(op));
#elif (defined SLJIT_CONFIG_ARM_64 && SLJIT_CONFIG_ARM_64)
    int r = sljit_get_register_index(SLJIT_GP_REGISTER, reg);
    sljit_u32 op;
    if (r < 0 || r > 30) return -1;
    /* ADD SP, Xr, #0 or ADD Xr, SP, #0 (MOV to and from SP). */
    op = to_sp ? (0x91000000u | ((sljit_u32)r << 5) | 31u) : (0x91000000u | (31u << 5) | (sljit_u32)r);
    return sljit_emit_op_custom(compiler, &op, sizeof(op));
#else
    (void)compiler; (void)reg; (void)to_sp;
    return -1;
#endif
}

int sljit_shim_info(int key)
{
    switch (key) {
    case 0: return SLJIT_NUMBER_OF_REGISTERS;
    case 1: return SLJIT_NUMBER_OF_SAVED_REGISTERS;
    case 2: return SLJIT_NUMBER_OF_FLOAT_REGISTERS;
    case 3: return SLJIT_NUMBER_OF_SAVED_FLOAT_REGISTERS;
    case 4: return SLJIT_NUMBER_OF_VECTOR_REGISTERS;
    default: return 0;
    }
}

sljit_uw sljit_shim_code_size(struct sljit_compiler *compiler)
{
    return sljit_get_generated_code_size(compiler);
}

sljit_uw sljit_shim_label_addr(struct sljit_label *label)
{
    return sljit_get_label_addr(label);
}

sljit_uw sljit_shim_jump_addr(struct sljit_jump *jump)
{
    return sljit_get_jump_addr(jump);
}

sljit_sw sljit_shim_executable_offset(struct sljit_compiler *compiler)
{
    return sljit_get_executable_offset(compiler);
}

sljit_uw sljit_shim_const_addr(struct sljit_const *constant)
{
    return sljit_get_const_addr(constant);
}
