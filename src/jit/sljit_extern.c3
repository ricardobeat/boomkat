// SLJIT handles stay opaque. The shim exposes platform register encodings.
module boomkat::jit;

extern fn void* sljit_create_compiler(void* allocator_data);
extern fn void sljit_free_compiler(void* compiler);
extern fn long sljit_emit_enter(void* compiler, int options, int arg_types,
    int scratches, int saveds, int local_size);
extern fn long sljit_emit_op0(void* compiler, int op);
extern fn long sljit_emit_op1(void* compiler, int op,
    int dst, long dstw, int src, long srcw);
extern fn long sljit_emit_op2(void* compiler, int op,
    int dst, long dstw, int src1, long src1w, int src2, long src2w);
extern fn void* sljit_emit_label(void* compiler);
extern fn void* sljit_emit_jump(void* compiler, int type);
extern fn void* sljit_emit_cmp(void* compiler, int type,
    int src1, long src1w, int src2, long src2w);
extern fn void sljit_set_label(void* jump, void* label);
extern fn long sljit_emit_return(void* compiler, int op, int src, long srcw);
extern fn void* sljit_generate_code(void* compiler, int options, void* exec_allocator_data);
extern fn void sljit_free_code(void* code, void* exec_allocator_data);
extern fn int sljit_shim_info(int key);
extern fn usz sljit_shim_code_size(void* compiler);

const int SLJIT_IMM = 0x7f;
const int SLJIT_MEM = 0x80;
const int SLJIT_LMUL_UW = 2;
const int SLJIT_MOV = 32;
const int SLJIT_MOV_U8 = 33;
const int SLJIT_MOV_U32 = 37;
const int SLJIT_ADD = 64;
const int SLJIT_SUB = 66;
const int SLJIT_MUL = 68;
const int SLJIT_AND = 69;
const int SLJIT_SHL = 72;
const int SLJIT_LSHR = 74;
const int SLJIT_ASHR = 76;
const int SLJIT_EQUAL = 0;
const int SLJIT_NOT_EQUAL = 1;
const int SLJIT_LESS = 2;
const int SLJIT_GREATER_EQUAL = 3;
const int SLJIT_GREATER = 4;
const int SLJIT_LESS_EQUAL = 5;
const int SLJIT_SIG_GREATER_EQUAL = 7;
const int SLJIT_JUMP = 36;
const int SLJIT_ARGS3WWW = 0x1111;

fn int reg_r(int i) @inline => 1 + i;
fn int reg_s(int i) @inline => sljit_shim_info(0) - i;

fn bool bind_sljit_runtime() {
    return sljit_shim_info(0) >= 13 && sljit_shim_info(1) >= 5;
}
