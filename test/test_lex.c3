module test_lex;

import boomkat::heap;
import boomkat::lexer;
import std::io;

fn int main() {
    char[] source = "var x = 42;";
    
    Heap* heap = heap::create(null, null, null, null, null)!!;
    
    io::printfn("Tokenizing: var x = 42;");
    
    lexer::Lexer lex = lexer::lexer_init(source, (void*)heap);
    
    for (int i = 0; i < 10; i++) {
        lexer::Token tok = lex.next_token()!!;
        io::printfn("Token %d: type=%d, line=%d, col=%d", i, tok.type.ordinal, tok.line, tok.col);
        if (tok.type == lexer::TokenType.EOF_TOKEN) break;
    }
    
    heap.destroy();
    return 0;
}
