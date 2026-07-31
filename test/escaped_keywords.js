// Escaped keywords and legacy octal escapes (ES2024 §5.1.5, §12.7.2, §12.9.4.1).
//
// Two distinct rules live here:
//
//  (a) A ReservedWord is a terminal symbol and must appear literally. A
//      spelling that uses a Unicode escape (`var`, `break`) is neither
//      the keyword nor a usable Identifier — always a SyntaxError. The same
//      goes for the contextual keywords in the positions where the grammar
//      demands the terminal (`get`/`set` accessors, `async` methods,
//      `new.target`) and for `true`/`false`/`null`. An escape in an
//      IdentifierName position (a property key, a member access) stays legal.
//
//  (b) A LegacyOctalEscapeSequence in a string literal is a SyntaxError in
//      strict code, including in a DirectivePrologue member — the position
//      that is never evaluated as an expression.
//
// Runs unmodified under node (`node test/escaped_keywords.js`) with the shim
// below, so the expectations are V8-verified.
if (typeof print === "undefined") { var print = function (s) { console.log(s); }; }

var pass = 0;
var fail = 0;

function rejects(label, src) {
    var threw = false;
    try {
        Function('"use strict";\n' + src);
    } catch (e) {
        threw = (e instanceof SyntaxError);
    }
    if (threw) { pass++; }
    else { fail++; print("FAIL: expected SyntaxError for " + label + " -- [" + src + "]"); }
}

function accepts(label, src) {
    try {
        Function('"use strict";\n' + src);
        pass++;
    } catch (e) {
        fail++;
        print("FAIL: expected " + label + " to parse -- [" + src + "] threw " + e);
    }
}

// Build a keyword spelled with its first character as a \uXXXX escape.
function esc(word) {
    return "\\u" + ("000" + word.charCodeAt(0).toString(16)).slice(-4) + word.slice(1);
}

// --- (a1) escaped ReservedWord in a hard-keyword position ---
var HARD = ["var", "if", "function", "return", "typeof", "this", "new", "delete",
            "void", "in", "instanceof", "do", "for", "while", "switch", "try",
            "throw", "class", "const", "super", "export", "import", "enum",
            "extends", "break", "continue", "debugger", "case", "catch",
            "default", "else", "finally"];
for (var i = 0; i < HARD.length; i++) {
    // As an IdentifierReference / BindingIdentifier the escaped reserved word
    // must not slip through as a plain identifier.
    rejects("escaped reserved word " + HARD[i] + " as binding",
            "var " + esc(HARD[i]) + " = 1;");
    // ...nor be silently accepted as a destructuring shorthand reference.
    rejects("escaped reserved word " + HARD[i] + " as dstr shorthand",
            "var x = { " + esc(HARD[i]) + " } = { " + HARD[i] + ": 42 };");
}

// --- (a2) `true` / `false` / `null` are ReservedWords too ---
rejects("escaped true literal",  "tru\\u0065;");
rejects("escaped false literal", "f\\u0061lse;");
rejects("escaped null literal",  "n\\u0075ll;");
rejects("escaped true label",    "tru\\u0065: ;");
rejects("escaped false label",   "f\\u0061lse: ;");
rejects("escaped null label",    "nul\\u006c: ;");
// ...and they are not valid label names unescaped either.
rejects("true as label",         "true: ;");
rejects("false as label",        "false: ;");
rejects("null as label",         "null: ;");

// --- (a3) contextual keywords must be literal where the grammar needs them ---
rejects("escaped get accessor",     "({ g\\u0065t m() {} });");
rejects("escaped get first char",   "({ \\u0067et m() {} });");
rejects("escaped get last char",    "({ ge\\u0074 m() {} });");
rejects("escaped get all chars",    "({ \\u0067\\u0065\\u0074 m() {} });");
rejects("escaped set accessor",     "({ s\\u0065t m(v) {} });");
rejects("escaped set first char",   "({ \\u0073et m(v) {} });");
rejects("escaped set last char",    "({ se\\u0074 m(v) {} });");
rejects("escaped set all chars",    "({ \\u0073\\u0065\\u0074 m(v) {} });");
rejects("escaped async method",     "({ \\u0061sync m(){} });");
rejects("escaped async gen method", "({ \\u0061sync* m(){} });");
rejects("escaped new in new.target",    "function f() { n\\u0065w.target; }");
rejects("escaped target in new.target", "function f() { new.t\\u0061rget; }");

// --- (a4) ACCEPT side: escapes are legal in IdentifierName positions ---
accepts("escaped property key",        "({ \\u0062reak: 1 });");
accepts("escaped shorthand method",    "({ \\u0062reak(){} });");
accepts("escaped class method name",   "class C { \\u0062reak(){} }");
accepts("escaped member access",       "var o = { break: 1 }; o.\\u0062reak;");
accepts("escaped key get",             "({ \\u0067et: 1 });");
accepts("escaped key set",             "({ \\u0073et: 1 });");
accepts("escaped key async",           "({ \\u0061sync: 1 });");
accepts("escaped class key get",       "class C { \\u0067et(){} }");
// ...and always legal inside ordinary, non-reserved identifiers.
accepts("escaped plain identifier",    "var \\u0061bc = 1; abc;");
accepts("escaped identifier ref",      "var abc = 1; \\u0061bc;");
accepts("escaped identifier middle",   "var a\\u0062c = 1; abc;");
accepts("escaped identifier getter",   "var g\\u0065tter = 1; getter;");
accepts("escaped identifier asyncx",   "var \\u0061syncx = 1; asyncx;");
accepts("escaped dstr shorthand",      "var { \\u0061bc } = { abc: 1 };");
accepts("escaped non-ascii identifier","var \\u00e9 = 1;");
// get/set/async stay ordinary identifiers, escaped or not.
accepts("get as plain identifier",     "var get = 1; get;");
accepts("set as plain identifier",     "var set = 1; set;");
accepts("async as plain identifier",   "var async = 1; async;");
accepts("escaped get as identifier",   "var \\u0067et = 1; get;");
accepts("escaped set as identifier",   "var \\u0073et = 1; set;");
accepts("escaped async as identifier", "var \\u0061sync = 1; async;");
// ...and the unescaped contextual forms must keep working.
accepts("plain get accessor",          "({ get m() { return 1; } });");
accepts("plain set accessor",          "({ set m(v) {} });");
accepts("plain accessor pair",         "({ get m(){ return 1; }, set m(v){} });");
accepts("plain async method",          "({ async m(){} });");
accepts("plain async gen method",      "({ async* m(){} });");
accepts("plain new.target",            "function f(){ new.target; }");
accepts("plain label",                 "foo: for(;;) break foo;");
accepts("class accessor",              "class C { get m(){ return 1; } }");

// --- (b) legacy octal escapes, including in a directive prologue ---
rejects("octal escape in prologue",
        '(function() {\n  "asterisk: \\052";\n  "use strict";\n});');
rejects("octal escape in nested prologue",
        'function f() {\n  "asterisk: \\052";\n}');
rejects("octal escape after directives",
        '(function() {\n  "a";\n  "b";\n  "asterisk: \\052";\n});');
rejects("octal escape in expression",  'var s = "\\052";');
rejects("octal escape \\1",            'var s = "\\1";');
rejects("octal escape \\8 identity",   'var s = "\\8";');
rejects("NUL followed by a digit",     'var s = "\\00";');
accepts("plain NUL escape",            'var s = "\\0";');
accepts("hex escape",                  'var s = "\\x2a";');
accepts("unicode escape",              'var s = "\\u002a";');
accepts("ordinary directive prologue", '(function() {\n  "use strict";\n  return 1;\n});');
accepts("non-octal directive",         '(function() {\n  "asterisk: \\x2a";\n  "use strict";\n});');

// --- the accessor / async forms must still WORK, not merely parse ---
function runtimeEquals(label, src, expected) {
    var got;
    try {
        got = String(Function('"use strict";\n' + src)());
    } catch (e) {
        got = "threw " + e;
    }
    if (got === expected) { pass++; }
    else { fail++; print("FAIL: " + label + " -- expected [" + expected + "] got [" + got + "]"); }
}

runtimeEquals("getter still works",
    "var o = { get m() { return 7; } }; return o.m;", "7");
runtimeEquals("setter still works",
    "var seen, o = { set m(v) { seen = v; } }; o.m = 9; return seen;", "9");
runtimeEquals("escaped key reads back",
    "var o = { \\u0062reak: 3 }; return o.break;", "3");
runtimeEquals("escaped member access reads back",
    "var o = { break: 4 }; return o.\\u0062reak;", "4");
runtimeEquals("escaped identifier is the same binding",
    "var \\u0061bc = 5; return abc;", "5");

print("escaped_keywords: " + pass + " passed, " + fail + " failed");
if (fail > 0) {
    print("SOME TESTS FAILED");
    throw new Error("FAIL");
}
