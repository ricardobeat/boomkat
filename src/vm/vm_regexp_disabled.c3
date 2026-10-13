// The image reader rejects regexp opcodes before reaching this provider.
module boomkat::vm @feat(NO_REGEXP);

import boomkat::types;
import boomkat::bytecode;

fn void? vm_retest(Dispatch* ds, TVal* ra, TVal* rb, DecodedInsn insn) {
    return VM_ERROR~;
}

macro TVal? vm_new_regexp(Dispatch* ds, TVal* ra, DecodedInsn insn) {
    return VM_ERROR~;
}
