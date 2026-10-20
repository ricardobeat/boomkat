#include "sljitLir.h"

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
