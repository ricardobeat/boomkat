module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;

// ============================================================================
// Error recording helper
// ============================================================================

// Record a compile error with the current lexer position, then return COMPILE_ERROR~.
// Callers: `return self.fail("message")!;` or `return self.fail("message");`
macro fault CompilerContext.fail(&self, char[] msg) {
    if (self.lexer.err_msg[0] == 0) {
        self.lexer.err_line = self.lexer.line;
        self.lexer.err_col  = self.lexer.col;
        // Copy msg into fixed buffer (truncate if necessary, always NUL-terminate).
        usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
        mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
        self.lexer.err_msg[copy_len] = 0;
    }
    return COMPILE_ERROR;
}
