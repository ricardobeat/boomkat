// ES2024 §12.4: a MultiLineComment must be closed.
//
//   MultiLineComment :: `/*` MultiLineCommentChars? `*/`
//
// There is no production for one that runs to end-of-input, so it is a
// SyntaxError. The lexer used to break out of the comment scan on end-of-input
// and return EOF, which silently compiled the source as though it ended just
// before the `/*` — including the `/*/` case, where the `/` that looks like it
// closes the comment is actually part of the opening `/*`.
//
// Every expectation below matches `node --check` on the same source.

function syntaxError(source) {
    try {
        eval(source);
        return false;
    } catch (e) {
        return e instanceof SyntaxError;
    }
}

var pass = 0;
var fail = 0;
function assert(cond, msg) {
    if (cond) {
        pass++;
    } else {
        fail++;
        print("FAIL:", msg);
    }
}

// --- unterminated -------------------------------------------------------
assert(syntaxError("/*unterminated"), "bare unterminated comment");
assert(syntaxError("/*CHECK#1/"), "a lone `/` does not close a comment");
assert(syntaxError("/*/"), "`/*/` is an unterminated comment, not an empty one");
assert(syntaxError("1; /*x"), "unterminated comment after a statement");
assert(syntaxError("/* a\nb\nc"), "unterminated multi-line comment");
// Comments do not nest, so the first `*/` closes the whole thing.
assert(!syntaxError("/* outer /* inner */"), "an inner `/*` opens nothing");
assert(syntaxError("/* outer /* inner */ */"), "the trailing `*/` is then stray");

// --- properly terminated ------------------------------------------------
assert(!syntaxError("/* ok */ 1"), "closed comment before a statement");
assert(!syntaxError("1 /* ok */"), "closed comment after a statement");
assert(!syntaxError("/**/ 1"), "empty comment");
assert(!syntaxError("/* a\nb */ 1"), "closed comment spanning lines");
assert(!syntaxError("1 // to end of line"), "single-line comment needs no closer");
assert(!syntaxError("var re = /a*/; re.source"), "a regexp containing `*` is not a comment");

print("=== Results:", pass, "pass,", fail, "fail ===");
