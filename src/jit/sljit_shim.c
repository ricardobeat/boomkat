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


int sljit_shim_info(int key)
{
    switch (key) {
    case 0: return SLJIT_NUMBER_OF_REGISTERS;
    case 1: return SLJIT_NUMBER_OF_SAVED_REGISTERS;
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
