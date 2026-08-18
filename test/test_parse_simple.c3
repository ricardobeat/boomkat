module test_parse_simple;

import boomkat::heap;
import boomkat::lexer;
import std::io;

fn int main() {
    char[] source = "42";
    
    Heap* heap = heap::create(null, null, null, null, null)!!;
    
    io::printfn("Parsing: 42");
    
    parser::Parser p = parser::parser_init(heap, source)!!;
    
    io::printfn("Parser initialized, calling parse_program...");
    
    uint program = p.parse_program()!!;
    
    if (p.has_error) {
        io::printfn("Parse error");
        heap.destroy();
        return 1;
    }
    
    io::printfn("Parse successful! Node count: %d", p.node_count);
    
    heap.destroy();
    return 0;
}
