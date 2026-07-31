// ES2024 §14.7.4: a C-style `for` head is parsed with the grammar's In
// parameter set to `[~In]`:
//
//   for ( Expression[~In]opt ; Expressionopt ; Expressionopt ) Statement
//   for ( var VariableDeclarationList[~In] ; ... )
//   for ( LexicalDeclaration[~In] ... )
//
// so a top-level `in` there is a SyntaxError rather than being read as a
// for-in head that then trips over the `;`. `[~In]` covers the whole left
// spine (comma, assignment, conditional, binary) but is re-fixed to `[+In]`
// by every nested grouping, and by a conditional's MIDDLE operand only:
//
//   ConditionalExpression[?In] :
//     ShortCircuitExpression[?In] ? AssignmentExpression[+In]
//                                 : AssignmentExpression[?In]
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

// --- rejected: an unparenthesized `in` at the head's top level -------------
assert(syntaxError("for (1 in [1]; 1;) { break; }"), "bare `in` as the whole init");
assert(syntaxError("for ('' in {} ? 0 : 0; false;) ;"), "`in` in a conditional's condition");
assert(syntaxError("for (true ? 0 : 0 in {}; false;) ;"), "`in` in a conditional's false branch");
assert(syntaxError("for (0 ? 0 : 1 ? 0 : 0 in {}; false;) ;"), "`in` in a nested false branch");
assert(syntaxError("for (var x = 1 in {}; false;) ;"), "`in` in a var declarator's initializer");
assert(syntaxError("for (var a = 0, b = 1 in {}; false;) ;"), "`in` in a later declarator");
assert(syntaxError("for (let y = 1 in {}; false;) ;"), "`in` in a let declarator");
assert(syntaxError("for (1 in {}, 2; false;) ;"), "`in` in a comma operand");

// --- accepted: `[+In]` is restored by any grouping ------------------------
assert(!syntaxError("for ((1 in {}); false;) ;"), "parenthesized `in`");
assert(!syntaxError("for (var x = ('a' in {}); false;) ;"), "parenthesized `in` in an initializer");
assert(!syntaxError("for ([1 in {}]; false;) ;"), "`in` in an array element");
assert(!syntaxError("for (`${1 in {}}`; false;) ;"), "`in` in a template substitution");
assert(!syntaxError("function f() {} for (f(1 in {}); false;) ;"), "`in` in a call argument");

// --- accepted: only the head is `[~In]` ----------------------------------
assert(!syntaxError("for (true ? 0 in {} : 0; false;) ;"), "`in` in a conditional's true branch");
assert(!syntaxError("for (var i = 0; 'a' in {}; i++) ;"), "`in` in the condition clause");
assert(!syntaxError("for (var i = 0; false; 'a' in {}) ;"), "`in` in the increment clause");
assert(!syntaxError("for (;;) { 1 in {}; break; }"), "`in` in the loop body");
assert(!syntaxError("for (var k in {a: 1}) ;"), "an ordinary for-in head");
assert(!syntaxError("var q = true ? 0 : 0 in {};"), "`in` outside any for head");

print("=== Results:", pass, "pass,", fail, "fail ===");
