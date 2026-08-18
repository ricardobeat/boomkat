module test_parse;

import boomkat::heap;
import boomkat::lexer;
import std::io;

fn int main() {
    char[] source = "var x = 42; if (x > 10) { x = x + 1; }";
    
    Heap* heap = heap::create(null, null, null, null, null)!!;
    
    io::printfn("Parsing: %s", source);
    
    parser::Parser p = parser::parser_init(heap, source)!!;
    uint program = p.parse_program()!!;
    
    if (p.has_error) {
        io::printfn("Parse error at line %d, col %d", p.error_line, p.error_col);
        heap.destroy();
        return 1;
    }
    
    io::printfn("Parse successful! Root node: %d", program);
    io::printfn("Total AST nodes: %d", p.node_count);
    
    heap.destroy();
    return 0;
}
