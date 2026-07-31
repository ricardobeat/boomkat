// A contextual keyword written with a Unicode escape is NOT the keyword.
//
// ES2024 §12.6.1: a ReservedWord (and, by the same rule, the contextual
// keywords the grammar matches on their text) must be spelled with no
// UnicodeEscapeSequence. `of` is therefore a plain identifier and can
// never head a for-of loop -- `for (var x of [])` is a SyntaxError, not a
// loop over `[]`.
//
// `of` is the script-visible case; the module-only contextual keywords `as`
// and `from` follow the identical rule and are covered in
// test/modules/export_names.sh's sibling, test/modules/syntax_positions.sh.
//
// Each case is compiled in isolation via eval() because these are *early*
// errors: a direct source-level copy would fail to parse this whole file
// rather than exercise one rule at a time. The escape sequences are built by
// concatenation so that the backslash reaches the parser as source text rather
// than being consumed by this file's own string literals.
//
// This file is written to run UNMODIFIED under node (with a `print` shim), so
// the expectations are V8-verified rather than self-asserted.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Assert that `src` is an early SyntaxError.
function rejects(src) {
  var threw = null;
  try {
    eval('"use strict";\n' + src);
  } catch (e) {
    threw = e;
  }
  assert(threw !== null && threw instanceof SyntaxError,
         'expected SyntaxError for: ' + src +
         (threw === null ? ' (accepted)' : ' (got ' + threw.name + ')'));
}

// Assert that `src` parses AND runs cleanly. Over-rejection is the more
// damaging failure mode, so the valid shapes are asserted just as hard as the
// invalid ones.
function accepts(src) {
  var threw = null;
  try {
    eval('"use strict";\n' + src);
  } catch (e) {
    threw = e;
  }
  assert(threw === null,
         'expected clean parse+run for: ' + src +
         (threw === null ? '' : ' (got ' + threw.name + ': ' + threw.message + ')'));
}

var BS = String.fromCharCode(92);   // a literal backslash
var ESC_OF = 'o' + BS + 'u0066';    // `of` with the `f` escaped
var ESC_OF2 = BS + 'u006ff';        // `of` with the `o` escaped

// ---------------------------------------------------------------------------
// An escaped `of` cannot head a for-of loop, in any head shape
// ---------------------------------------------------------------------------

rejects('for (var x ' + ESC_OF + ' []) ;');
rejects('for (let x ' + ESC_OF + ' []) ;');
rejects('for (const x ' + ESC_OF + ' []) ;');
rejects('var t; for (t ' + ESC_OF + ' []) ;');
rejects('var a; for ([a] ' + ESC_OF + ' []) ;');
rejects('var a; for ({ p: a } ' + ESC_OF + ' []) ;');
rejects('for (var [a, b] ' + ESC_OF + ' []) ;');
rejects('for (var { p } ' + ESC_OF + ' []) ;');
rejects('var o = {}; for (o.p ' + ESC_OF + ' []) ;');

// Escaping the other character is the same rule.
rejects('for (var x ' + ESC_OF2 + ' []) ;');
rejects('var t; for (t ' + ESC_OF2 + ' []) ;');

// ---------------------------------------------------------------------------
// Accepts: the unescaped keyword still works in every head shape
// ---------------------------------------------------------------------------

accepts('var n = 0; for (var v of [1, 2, 3]) { n += v; } if (n !== 6) throw new Error("x");');
accepts('var n = 0; for (let v of [1, 2]) { n += v; } if (n !== 3) throw new Error("x");');
accepts('var n = 0; for (const v of [4]) { n = v; } if (n !== 4) throw new Error("x");');
accepts('var t, n = 0; for (t of [5]) { n = t; } if (n !== 5) throw new Error("x");');
accepts('var n = 0; for ([n] of [[7]]) {} if (n !== 7) throw new Error("x");');
accepts('var a, n = 0; for ({ p: a } of [{ p: 6 }]) { n = a; } if (n !== 6) throw new Error("x");');
accepts('var n = 0; for (var [a, b] of [[1, 2]]) { n = a + b; } if (n !== 3) throw new Error("x");');
accepts('var n = 0; for (var { p } of [{ p: 9 }]) { n = p; } if (n !== 9) throw new Error("x");');
accepts('var o = {}; for (o.p of [8]) {} if (o.p !== 8) throw new Error("x");');

// ---------------------------------------------------------------------------
// Accepts: `of` is not reserved, so it remains a perfectly good identifier --
// including when IT is the escaped one, since escaping only bars it from being
// read as the keyword.
// ---------------------------------------------------------------------------

accepts('var of = 3; if (of !== 3) throw new Error("x");');
accepts('var o = { of: 1 }; if (o.of !== 1) throw new Error("x");');
accepts('var ' + ESC_OF + ' = 4; if (of !== 4) throw new Error("x");');
accepts('var ' + ESC_OF2 + '2 = 5; if (of2 !== 5) throw new Error("x");');
accepts('function of() { return 6; } if (of() !== 6) throw new Error("x");');

// An identifier that merely CONTAINS the letters is unaffected either way.
accepts('var offset = 7; if (offset !== 7) throw new Error("x");');
accepts('var n = 0; for (var offset of [1]) { n = offset; } if (n !== 1) throw new Error("x");');

// for-in is a reserved-word head and is untouched by any of this.
accepts('var n = 0; for (var k in { a: 1 }) { n++; } if (n !== 1) throw new Error("x");');

print('escaped_contextual_keywords: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
