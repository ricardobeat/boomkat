module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import std::io;

// ============================================================================
// VM trace helpers (for --trace-vm)
//
// All bodies are gated on $feature(TRACE_VM). The CLI's `-t`/`--trace-vm`
// flag is recognised in the release build but does nothing (the
// runtime check `if (@unlikely(vm.trace))` in vm_execute.c3 is also
// gated), so users hitting `-t` on a release build silently get no
// trace output. Build `duktape_c3_debug` (`just build-trace`) for the
// full instruction trace.
// ============================================================================

/// Print a TVal to stderr (for --trace-vm debugging).
fn void trace_print_tval(TVal* v) {
$if $feature(TRACE_VM):
    switch (v.get_tag()) {
        case types::TValTag.UNDEFINED:  io::eprintf("undef");    break;
        case types::TValTag.NULL_VAL:   io::eprintf("null");     break;
        case types::TValTag.BOOLEAN:    io::eprintf(v.get_boolean() ? "true" : "false"); break;
        case types::TValTag.FASTINT:    io::eprintf("%d", v.get_fastint()); break;
        case types::TValTag.NUMBER:     io::eprintf("%g", v.get_number()); break;
        case types::TValTag.STRING: {
            HString* s = (HString*)v.get_heapptr();
            if (s != null) {
                char[] d = s.get_data();
                io::eprintf("\"");
                for (usz i = 0; i < d.len; i++) { io::eprintf("%c", d[i]); }
                io::eprintf("\"");
            } else { io::eprintf("(null)"); }
            break;
        }
        case types::TValTag.OBJECT: {
            HObject* o = (HObject*)v.get_heapptr();
            if (o != null) { io::eprintf("[object %d]", (int)o.flags.obj_class.ordinal); }
            else           { io::eprintf("[object (null)]"); }
            break;
        }
        default: io::eprintf("<?>"); break;
    }
$else
    // Stub for non-TRACE_VM builds. Keep callers in vm_execute.c3 linkable.
    (void)v;
$endif
}

/// Trace a single instruction before dispatch (for --trace-vm).
/// Writes to stderr so it doesn't interfere with program output.
fn void trace_instruction(Vm* vm, Instruction* ip, uint offset, DecodedInsn* di,
                          TVal* ra, TVal* rb, TVal* rc,
                          TVal* regs_base, Activation* act) {
$if $feature(TRACE_VM):
    char[160] line_buf;
    usz written = ip.disassemble(line_buf[..]);
    uint end = written < (usz)line_buf.len ? (uint)written : line_buf.len;
    io::eprintf("[0x%04X] %s  | ", offset, (String)line_buf[0:end]);

    // Print register values for the operands. The indices come from the
    // decoded instruction, so a WIDE-prefixed instruction shows its
    // effective 16-bit registers even though the raw word holds only the
    // low bytes.
    uint a = di.a;
    uint b = di.b;
    uint c = di.c;
    io::eprintf("r%d=", a); trace_print_tval(ra);
    io::eprintf(" r%d=", b); trace_print_tval(rb);
    if (c != 0 || di.op != Opcode.NOP) {
        io::eprintf(" r%d=", c); trace_print_tval(rc);
    }
    io::eprintf("\n");
$else
    // Stub for non-TRACE_VM builds. Call in vm_execute.c3 is similarly
    // gated, so this body is unreachable in release builds.
    (void)vm; (void)ip; (void)offset; (void)di; (void)ra; (void)rb; (void)rc; (void)regs_base; (void)act;
$endif
}
