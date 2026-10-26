// SLJIT handles stay opaque. The shim exposes platform register encodings.
module boomkat::jit;

extern fn void* sljit_create_compiler(void* allocator_data);
extern fn void sljit_free_compiler(void* compiler);
extern fn long sljit_emit_enter(void* compiler, int options, int arg_types, int scratches, int saveds, int local_size);
extern fn long sljit_emit_op0(void* compiler, int op);
extern fn long sljit_emit_op1(void* compiler, int op, int dst, long dstw, int src, long srcw);
extern fn long sljit_emit_op2(void* compiler, int op, int dst, long dstw, int src1, long src1w, int src2, long src2w);
extern fn int sljit_emit_fop1(void* compiler, int op, int dst, long dw, int src, long sw);
extern fn int sljit_emit_fop2(void* compiler, int op, int dst, long dw, int left, long lw, int right, long rw);
extern fn int sljit_emit_fcopy(void* compiler, int op, int freg, int reg);
extern fn void* sljit_emit_fcmp(void* compiler, int op, int left, long lw, int right, long rw);
extern fn void* sljit_emit_label(void* compiler);
extern fn void* sljit_emit_jump(void* compiler, int type);
extern fn void* sljit_emit_cmp(void* compiler, int type, int src1, long src1w, int src2, long src2w);
extern fn void sljit_set_label(void* jump, void* label);
extern fn long sljit_emit_return(void* compiler, int op, int src, long srcw);
extern fn void* sljit_generate_code(void* compiler, int options, void* exec_allocator_data);
extern fn void sljit_free_code(void* code, void* exec_allocator_data);
extern fn int sljit_shim_sqrt_f64(void* compiler, int freg);
extern fn int sljit_shim_info(int key);
extern fn usz sljit_shim_code_size(void* compiler);
extern fn usz sljit_shim_label_addr(void* label);
extern fn int sljit_emit_ijump(void* compiler, int type, int src, long sw);
extern fn int sljit_emit_icall(void* compiler, int type, int arg_types, int src, long sw);

const int SLJIT_IMM               = 0x7f;
const int SLJIT_MEM               = 0x80;
const int SLJIT_LMUL_UW           = 2;
const int SLJIT_MOV               = 32;
const int SLJIT_MOV_U8            = 33;
const int SLJIT_MOV_S8            = 34;
const int SLJIT_MOV_U16           = 35;
const int SLJIT_MOV_S16           = 36;
const int SLJIT_MOV_S32           = 38;
const int SLJIT_MOV_U32           = 37;
const int SLJIT_ADD               = 64;
const int SLJIT_SUB               = 66;
const int SLJIT_MUL               = 68;
const int SLJIT_AND               = 69;
const int SLJIT_OR                = 70;
const int SLJIT_XOR               = 71;
const int SLJIT_SHL               = 72;
const int SLJIT_LSHR              = 74;
const int SLJIT_ASHR              = 76;
const int SLJIT_EQUAL             = 0;
const int SLJIT_NOT_EQUAL         = 1;
const int SLJIT_LESS              = 2;
const int SLJIT_GREATER_EQUAL     = 3;
const int SLJIT_GREATER           = 4;
const int SLJIT_LESS_EQUAL        = 5;
const int SLJIT_SIG_LESS          = 6;
const int SLJIT_SIG_GREATER_EQUAL = 7;
const int SLJIT_SIG_GREATER       = 8;
const int SLJIT_SIG_LESS_EQUAL    = 9;
const int SLJIT_JUMP              = 36;
const int SLJIT_CALL              = 38;
const int SLJIT_ARGS2WWW          = 0x111;
const int SLJIT_ARGS3WWW          = 0x1111;

fn int reg_r(int i) @inline => 1 + i;
fn int reg_s(int i) @inline => sljit_shim_info(0) - i;

fn bool bind_sljit_runtime() {
    return sljit_shim_info(0) >= 13 && sljit_shim_info(1) >= 5;
}

const int SLJIT_MOV_F64           = 144;
const int SLJIT_CONV_F64_FROM_F32 = 145;
const int SLJIT_CONV_SW_FROM_F64  = 146;
const int SLJIT_CONV_F64_FROM_SW  = 148;
const int SLJIT_ADD_F64           = 176;
const int SLJIT_SUB_F64           = 177;
const int SLJIT_MUL_F64           = 178;
const int SLJIT_DIV_F64           = 179;

const int SLJIT_32                    = 0x100;
const int SLJIT_COPY_TO_F64           = 1;
const int SLJIT_COPY_FROM_F64         = 2;
const int SLJIT_NEG_F64               = 153;
const int SLJIT_UNORDERED                  = 22;
const int SLJIT_ORDERED                    = 23;
const int SLJIT_ORDERED_EQUAL              = 24;
const int SLJIT_UNORDERED_OR_NOT_EQUAL     = 25;
const int SLJIT_ORDERED_LESS               = 26;
const int SLJIT_UNORDERED_OR_GREATER_EQUAL = 27;
const int SLJIT_ORDERED_GREATER            = 28;
const int SLJIT_UNORDERED_OR_LESS_EQUAL    = 29;
const int SLJIT_UNORDERED_OR_EQUAL         = 30;
const int SLJIT_ORDERED_NOT_EQUAL          = 31;
const int SLJIT_UNORDERED_OR_LESS          = 32;
const int SLJIT_ORDERED_GREATER_EQUAL      = 33;
const int SLJIT_UNORDERED_OR_GREATER       = 34;
const int SLJIT_ORDERED_LESS_EQUAL         = 35;

const int SLJIT_ABS_F64 = 154;