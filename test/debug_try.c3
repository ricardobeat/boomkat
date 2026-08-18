module test;

import boomkat::lexer;
import boomkat::compiler;
import boomkat::bytecode;
import boomkat::types;
import std::io;
import libc;

fn int main(String[] args) {
    if (args.len < 2) {
        io::eprintfn("Usage: boomkat <file.js>");
        return 1;
    }
    
    // Simple compile to check TRY encodings
    // Read file
    // ... this is too complex for a debug test
    
    // Just check that make_a_bc works for NOP
    Instruction insn = bytecode::make_a_bc(Opcode.NOP, 0, 42);
    io::printfn("NOP raw: 0x%x", insn.to_raw());
    io::printfn("NOP op: %d (expect %d)", insn.op.ordinal, Opcode.NOP.ordinal);
    io::printfn("NOP a: %d (expect 0)", insn.a);
    io::printfn("NOP bc: %d (expect 42)", insn.get_bc());
    
    return 0;
}
