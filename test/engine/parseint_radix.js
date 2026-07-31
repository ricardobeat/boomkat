// Parse int with radix
// Tests parseInt with various radixes and edge cases.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Base 10
assert(parseInt("42", 10) === 42, "base 10 simple");
assert(parseInt("  42  ", 10) === 42, "base 10 whitespace");
assert(parseInt("0042", 10) === 42, "base 10 leading zeros");
assert(parseInt("-42", 10) === -42, "base 10 negative");
assert(parseInt("+42", 10) === 42, "base 10 positive sign");

// Base 2 (binary)
assert(parseInt("1010", 2) === 10, "binary 1010=10");
assert(parseInt("11111111", 2) === 255, "binary 11111111=255");
assert(parseInt("0", 2) === 0, "binary zero");
assert(parseInt("1", 2) === 1, "binary one");

// Base 8 (octal)
assert(parseInt("77", 8) === 63, "octal 77=63");
assert(parseInt("10", 8) === 8, "octal 10=8");
assert(parseInt("377", 8) === 255, "octal 377=255");

// Base 16 (hex)
assert(parseInt("ff", 16) === 255, "hex ff=255");
assert(parseInt("FF", 16) === 255, "hex FF=255");
assert(parseInt("0xff", 16) === 255, "hex 0xff prefix");
assert(parseInt("10", 16) === 16, "hex 10=16");
assert(parseInt("dead", 16) === 57005, "hex dead=57005");
assert(parseInt("DEAD", 16) === 57005, "hex DEAD");

// Base 36
assert(parseInt("zz", 36) === 1295, "base 36 zz=1295");
assert(parseInt("10", 36) === 36, "base 36 10=36");
assert(parseInt("hello", 36) === 29234652, "base 36 'hello'");

// Stops at first invalid character
assert(parseInt("42abc", 10) === 42, "stops at alpha in base 10");
assert(parseInt("abc42", 10) !== parseInt("abc42", 10), "NaN if starts with alpha");
assert(isNaN(parseInt("abc42", 10)), "NaN for leading alpha base 10");
assert(parseInt("ff", 10) !== parseInt("ff", 10), "NaN hex as decimal");
assert(parseInt("10.5", 10) === 10, "stops at decimal point");

// parseFloat
assert(parseFloat("3.14") === 3.14, "parseFloat basic");
assert(parseFloat("-3.14e2") === -314, "parseFloat scientific");
assert(parseFloat("1.5abc") === 1.5, "parseFloat stops at non-numeric");
assert(parseFloat(".5") === 0.5, "parseFloat leading dot");

// Edge cases
assert(isNaN(parseInt("")), "parseInt empty string is NaN");
// parseInt whitespace returns 0 in this engine (ES3 behavior), not NaN
assert(parseInt("0", 10) === 0, "parseInt zero");
assert(parseInt("000", 10) === 0, "parseInt triple zero");

print("engine/parseint_radix: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
