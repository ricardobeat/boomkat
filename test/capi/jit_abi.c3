module jit_test;

import boomkat::jit;
import std::io;
import libc;

macro void @check(#condition) {
    if (!(#condition)) {
        io::eprintfn("JIT ABI check failed: %s", $stringify(#condition));
        libc::exit(1);
    }
}

fn int main() {
    check_native_convention();
    io::printn("JIT ABI: PASS");
    return 0;
}

// These are machine-code ABI tests, independent of JS frame and GC semantics.
// A normal C entry owns the saved registers. Its nested generated functions
// share S0..S2, including changes made by callees, and call a C helper safely.
struct AbiContext {
    long bias;
    long calls;
}
struct AbiCode {
    void* code;
    usz patch;
    long executable_offset;
}
alias AbiEntry = fn long(AbiContext* context, long value);

fn long abi_runtime_add(long value) @noinline => value + 7;

fn AbiCode abi_generate(void* compiler, void* jump = null) {
    void* code = jit::sljit_generate_code(compiler, 0, null);
    @check(code != null);
    return {
        .code = code,
        .patch = jump != null ? jit::sljit_shim_jump_addr(jump) : 0,
        .executable_offset = jit::sljit_shim_executable_offset(compiler)
    };
}

fn int abi_options() => jit::SLJIT_ENTER_REG_ARG | jit::enter_keep(3);

fn AbiCode abi_leaf(long addition) {
    void* c = jit::sljit_create_compiler(null);
    @check(c != null);
    defer jit::sljit_free_compiler(c);
    @check(jit::sljit_emit_enter(c, abi_options(), jit::SLJIT_ARGS1WW_R, 3, 3, 16) == 0);
    int r0            = jit::reg_r(0);
    int r1            = jit::reg_r(1);
    int s0            = jit::reg_s(0);
    int s1            = jit::reg_s(1);
    int s2            = jit::reg_s(2);
    AbiContext layout;
    long bias_offset  = (char*)&layout.bias - (char*)&layout;
    long calls_offset = (char*)&layout.calls - (char*)&layout;
    @check(jit::sljit_emit_op2(c, jit::SLJIT_ADD, r0, 0, r0, 0, jit::SLJIT_MEM | s0, bias_offset) == 0);
    @check(jit::sljit_emit_op2(c, jit::SLJIT_ADD, r0, 0, r0, 0, jit::SLJIT_IMM, addition) == 0);
    @check(jit::sljit_emit_op1(c, jit::SLJIT_MOV, r1, 0, jit::SLJIT_MEM | s0, calls_offset) == 0);
    @check(jit::sljit_emit_op2(c, jit::SLJIT_ADD, r1, 0, r1, 0, jit::SLJIT_IMM, 1) == 0);
    @check(jit::sljit_emit_op1(c, jit::SLJIT_MOV, jit::SLJIT_MEM | s0, calls_offset, r1, 0) == 0);
    @check(jit::sljit_emit_op2(c, jit::SLJIT_ADD, s1, 0, s1, 0, jit::SLJIT_IMM, 1) == 0);
    @check(jit::sljit_emit_op2(c, jit::SLJIT_ADD, s2, 0, s2, 0, jit::SLJIT_IMM, 2) == 0);
    @check(jit::sljit_emit_icall(c, jit::SLJIT_CALL, jit::SLJIT_ARGS1WW, jit::SLJIT_IMM, (long)&abi_runtime_add) == 0);
    @check(jit::sljit_emit_return(c, jit::SLJIT_MOV, r0, 0) == 0);
    return abi_generate(c);
}

fn AbiCode abi_fragment(long addition) {
    void* c = jit::sljit_create_compiler(null);
    @check(c != null);
    defer jit::sljit_free_compiler(c);
    // No prologue: this fragment inherits the generated callee's exact context.
    @check(jit::sljit_set_context(c, abi_options(), jit::SLJIT_ARGS1WW_R, 3, 3, 16) == 0);
    @check(jit::sljit_emit_op2(c, jit::SLJIT_ADD, jit::reg_r(0), 0, jit::reg_r(0), 0, jit::SLJIT_IMM, addition) == 0);
    @check(jit::sljit_emit_return(c, jit::SLJIT_MOV, jit::reg_r(0), 0) == 0);
    return abi_generate(c);
}

fn AbiCode abi_callee(void* leaf, void* fragment) {
    void* c = jit::sljit_create_compiler(null);
    @check(c != null);
    defer jit::sljit_free_compiler(c);
    @check(jit::sljit_emit_enter(c, abi_options(), jit::SLJIT_ARGS1WW_R, 3, 3, 16) == 0);
    void* jump = jit::sljit_emit_cmp(
        c,
        jit::SLJIT_SIG_LESS | jit::SLJIT_REWRITABLE_JUMP,
        jit::reg_r(0),
        0,
        jit::SLJIT_IMM,
        0
    );
    @check(jump != null);
    jit::sljit_set_target(jump, (usz)fragment);
    void* call = jit::sljit_emit_call(c, jit::SLJIT_CALL_REG_ARG, jit::SLJIT_ARGS1WW);
    @check(call != null);
    jit::sljit_set_target(call, (usz)leaf);
    @check(jit::sljit_emit_return(c, jit::SLJIT_MOV, jit::reg_r(0), 0) == 0);
    return abi_generate(c, jump);
}

fn AbiCode abi_entry(void* callee) {
    void* c = jit::sljit_create_compiler(null);
    @check(c != null);
    defer jit::sljit_free_compiler(c);
    @check(jit::sljit_emit_enter(c, 0, jit::SLJIT_ARGS2WWW_R, 3, 3, 16) == 0);
    @check(jit::sljit_emit_op1(c, jit::SLJIT_MOV, jit::reg_s(0), 0, jit::reg_r(0), 0) == 0);
    @check(jit::sljit_emit_op1(c, jit::SLJIT_MOV, jit::reg_s(1), 0, jit::SLJIT_IMM, 40) == 0);
    @check(jit::sljit_emit_op1(c, jit::SLJIT_MOV, jit::reg_s(2), 0, jit::SLJIT_IMM, 80) == 0);
    @check(jit::sljit_emit_op1(c, jit::SLJIT_MOV, jit::reg_r(0), 0, jit::reg_r(1), 0) == 0);
    void* call = jit::sljit_emit_call(c, jit::SLJIT_CALL_REG_ARG | jit::SLJIT_REWRITABLE_JUMP, jit::SLJIT_ARGS1WW);
    @check(call != null);
    jit::sljit_set_target(call, (usz)callee);
    @check(jit::sljit_emit_op2(c, jit::SLJIT_ADD, jit::reg_r(0), 0, jit::reg_r(0), 0, jit::reg_s(1), 0) == 0);
    @check(jit::sljit_emit_op2(c, jit::SLJIT_ADD, jit::reg_r(0), 0, jit::reg_r(0), 0, jit::reg_s(2), 0) == 0);
    @check(jit::sljit_emit_return(c, jit::SLJIT_MOV, jit::reg_r(0), 0) == 0);
    return abi_generate(c, call);
}

fn void check_native_convention() {
    check_condition_values();
    check_codegen_capabilities();
    AbiCode leaf       = abi_leaf(3);
    AbiCode other_leaf = abi_leaf(13);
    defer jit::sljit_free_code(leaf.code, null);
    defer jit::sljit_free_code(other_leaf.code, null);
    AbiCode fragment       = abi_fragment(100);
    AbiCode other_fragment = abi_fragment(200);
    defer jit::sljit_free_code(fragment.code, null);
    defer jit::sljit_free_code(other_fragment.code, null);
    AbiCode callee       = abi_callee(leaf.code, fragment.code);
    AbiCode other_callee = abi_callee(other_leaf.code, fragment.code);
    defer jit::sljit_free_code(callee.code, null);
    defer jit::sljit_free_code(other_callee.code, null);
    AbiCode entry = abi_entry(callee.code);
    defer jit::sljit_free_code(entry.code, null);
    AbiEntry run       = (AbiEntry)entry.code;
    AbiContext context = { .bias = 11 };
    for (long i = 0; i < 1000; i++) @check(run(&context, i) == i + 144);
    @check(context.calls == 1000);
    @check(run(&context, -1) == 219 && context.calls == 1000);
    // Patch a separately generated branch and then a generated call. Retain
    // executable offsets before freeing compiler objects; never assume zero.
    jit::sljit_set_jump_addr(callee.patch, (usz)other_fragment.code, callee.executable_offset);
    @check(run(&context, -1) == 319 && context.calls == 1000);
    jit::sljit_set_jump_addr(entry.patch, (usz)other_callee.code, entry.executable_offset);
    @check(run(&context, 5) == 159 && context.calls == 1001);
    @check(run(&context, -1) == 219 && context.calls == 1001);
}
alias AbiCompare = fn long(long left, long right);

fn void check_condition_values() {
    void* compiler = jit::sljit_create_compiler(null);
    @check(compiler != null);
    defer jit::sljit_free_compiler(compiler);
    @check(jit::sljit_emit_enter(compiler, 0, jit::SLJIT_ARGS2WWW_R, 2, 0, 0) == 0);
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    @check(jit::sljit_emit_op2(compiler, jit::SLJIT_SUB | jit::SLJIT_SET_Z, r0, 0, r0, 0, r1, 0) == 0);
    @check(jit::sljit_emit_op_flags(compiler, jit::SLJIT_MOV, r0, 0, jit::SLJIT_EQUAL) == 0);
    @check(jit::sljit_emit_return(compiler, jit::SLJIT_MOV, r0, 0) == 0);
    AbiCode generated = abi_generate(compiler);
    defer jit::sljit_free_code(generated.code, null);
    AbiCompare compare = (AbiCompare)generated.code;
    @check(compare(0, 0) == 1);
    @check(compare(-1, -1) == 1);
    @check(compare(-1, 1) == 0);
    @check(compare(long::min, long::max) == 0);
}

alias AbiIndexed = fn long(long* values, long index);
alias AbiBuffer = fn long(char* buffer);
alias AbiPair = fn long(long* values);

fn void check_codegen_capabilities() {
    @check(jit::sljit_has_cpu_feature(jit::SLJIT_HAS_FPU) != 0);
    @check(jit::sljit_shim_info(2) >= 10);
    void* compiler = jit::sljit_create_compiler(null);
    @check(compiler != null);
    defer jit::sljit_free_compiler(compiler);
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    @check(jit::sljit_emit_enter(compiler, 0, jit::SLJIT_ARGS2WWW_R, 2, 0, 0) == 0);
    @check(jit::sljit_emit_op1(compiler, jit::SLJIT_MOV, r0, 0, jit::mem_index(r0, r1), 3) == 0);
    @check(jit::sljit_emit_op2(compiler, jit::SLJIT_MSHL | jit::SLJIT_32, r0, 0, r0, 0, jit::SLJIT_IMM, 36) == 0);
    @check(jit::sljit_emit_op2(compiler, jit::SLJIT_ROTL | jit::SLJIT_32, r0, 0, r0, 0, jit::SLJIT_IMM, 8) == 0);
    @check(jit::sljit_emit_op2u(compiler, jit::SLJIT_SUB | jit::SLJIT_SET_Z, r0, 0, jit::SLJIT_IMM, 16384) == 0);
    @check(jit::sljit_emit_select(compiler, jit::SLJIT_EQUAL, r0, jit::SLJIT_IMM, 31, r0) == 0);
    void* constant = jit::sljit_emit_const(compiler, jit::SLJIT_MOV, r1, 0, 7);
    @check(constant != null);
    @check(jit::sljit_emit_op2(compiler, jit::SLJIT_ADD, r0, 0, r0, 0, r1, 0) == 0);
    @check(jit::sljit_emit_return(compiler, jit::SLJIT_MOV, r0, 0) == 0);
    AbiCode generated = abi_generate(compiler);
    defer jit::sljit_free_code(generated.code, null);
    AbiIndexed run = (AbiIndexed)generated.code;
    long[2] values = {2, 4};
    @check(run(&values[0], 1) == 38);
    @check(run(&values[0], 0) == 8199);
    jit::sljit_set_const(jit::sljit_shim_const_addr(constant), jit::SLJIT_MOV, 17, generated.executable_offset);
    @check(run(&values[0], 1) == 48);

    void* pair_compiler = jit::sljit_create_compiler(null);
    @check(pair_compiler != null);
    defer jit::sljit_free_compiler(pair_compiler);
    @check(jit::sljit_emit_enter(pair_compiler, 0, jit::SLJIT_ARGS1WW_R, 3, 0, 0) == 0);
    int pair = jit::reg_pair(r1, jit::reg_r(2));
    @check(jit::sljit_emit_mem(pair_compiler, jit::SLJIT_MOV, pair, jit::SLJIT_MEM | r0, 0) == 0);
    @check(jit::sljit_emit_mem(pair_compiler, jit::SLJIT_MOV | jit::SLJIT_MEM_STORE, pair, jit::SLJIT_MEM | r0, 16) == 0);
    @check(jit::sljit_emit_return(pair_compiler, jit::SLJIT_MOV, jit::SLJIT_IMM, 0) == 0);
    AbiCode pair_code = abi_generate(pair_compiler);
    defer jit::sljit_free_code(pair_code.code, null);
    long[4] pair_values = {11, 22, 0, 0};
    @check(((AbiPair)pair_code.code)(&pair_values[0]) == 0);
    @check(pair_values[2] == 11 && pair_values[3] == 22);

    if (jit::sljit_has_cpu_feature(jit::SLJIT_HAS_SIMD) == 0) return;
    void* vector_compiler = jit::sljit_create_compiler(null);
    @check(vector_compiler != null);
    defer jit::sljit_free_compiler(vector_compiler);
    @check(jit::sljit_emit_enter(vector_compiler, 0, jit::SLJIT_ARGS1WW_R, 1 | (1 << 16), 0, 0) == 0);
    int type = jit::SLJIT_SIMD_REG_128 | jit::SLJIT_SIMD_ELEM_8;
    if (jit::sljit_emit_simd_replicate(vector_compiler, type | jit::SLJIT_SIMD_TEST, 1, jit::SLJIT_IMM, 0x5a) != 0) return;
    @check(jit::sljit_emit_simd_replicate(vector_compiler, type, 1, jit::SLJIT_IMM, 0x5a) == 0);
    @check(jit::sljit_emit_simd_mov(vector_compiler, type | jit::SLJIT_SIMD_STORE, 1, jit::SLJIT_MEM | r0, 0) == 0);
    @check(jit::sljit_emit_return(vector_compiler, jit::SLJIT_MOV, jit::SLJIT_IMM, 0) == 0);
    AbiCode vector_code = abi_generate(vector_compiler);
    defer jit::sljit_free_code(vector_code.code, null);
    char[16] buffer;
    @check(((AbiBuffer)vector_code.code)(&buffer[0]) == 0);
    foreach (byte : buffer) @check(byte == 0x5a);
}
