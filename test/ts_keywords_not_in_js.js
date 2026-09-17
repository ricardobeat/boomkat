// TypeScript declaration keywords must never be recognised in a .js file.
//
// `interface`, `implements`, `private`, `public`, `protected` are JS
// FutureReservedWords: reserved in strict code, ordinary identifiers in
// sloppy code. The TS parser paths that consume them are gated on the
// lexer's `ts_mode`, NOT on strictness — a sloppy .js file must still
// treat them as plain identifiers, and a sloppy .ts file must still see
// the TS declarations. Guards the coupling fixed alongside sloppy mode:
// keying TS dispatch off the strict-only keyword table silently disabled
// TS syntax in sloppy .ts files.

var pass = 0;
var fail = 0;
function assert(cond, msg) {
    if (cond) { pass = pass + 1; }
    else { print("FAIL: " + msg); fail = fail + 1; }
}

// --- TS syntax must not parse in a .js file (sloppy) ---
var ts_forms = [
    "interface A { x: string; }",
    "class C implements A { }",
    "class C { private x = 1; }",
    "class C { public x = 1; }",
    "class C { protected x = 1; }",
    "type T = string;",
    "namespace N { }",
    "declare const q: number;"
];
for (var i = 0; i < ts_forms.length; i++) {
    var threw = false;
    try { eval(ts_forms[i]); } catch (e) { threw = e instanceof SyntaxError; }
    assert(threw, "TS syntax rejected in .js: " + ts_forms[i]);
}

// --- they remain usable as ordinary identifiers in sloppy code ---
var interface = 1, implements = 2, private = 3, public = 4, protected = 5;
assert(interface + implements + private + public + protected === 15,
       "FutureReservedWords usable as sloppy identifiers");

// --- and remain reserved in strict code ---
var strict_reserved = ["interface", "implements", "private", "public", "protected"];
for (var j = 0; j < strict_reserved.length; j++) {
    var threw2 = false;
    try { eval('"use strict"; var ' + strict_reserved[j] + ' = 1;'); }
    catch (e2) { threw2 = e2 instanceof SyntaxError; }
    assert(threw2, "reserved in strict: " + strict_reserved[j]);
}

print("ts_keywords_not_in_js: " + pass + " passed, " + fail + " failed");
if (fail > 0) { throw new Error("ts_keywords_not_in_js failed"); }
