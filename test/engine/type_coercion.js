// Type coercion
// Tests JS implicit/explicit coercion, ==, ===, truthy/falsy.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Number coercion
assert(Number("42") === 42, "Number(string)");
assert(Number("") === 0, "Number(empty string) = 0");
assert(Number("abc") !== Number("abc"), "Number(NaN) is NaN");
assert(isNaN(Number("abc")), "Number('abc') is NaN");
assert(Number(true) === 1, "Number(true) = 1");
assert(Number(false) === 0, "Number(false) = 0");
assert(Number(null) === 0, "Number(null) = 0");
assert(isNaN(Number(undefined)), "Number(undefined) is NaN");

// String coercion
assert(String(42) === "42", "String(42)");
assert(String(true) === "true", "String(true)");
assert(String(null) === "null", "String(null)");
assert(String(undefined) === "undefined", "String(undefined)");
assert("" + 123 === "123", "concat number to string");

// Boolean coercion (truthy/falsy)
assert(!0, "0 is falsy");
assert(!"", "empty string is falsy");
assert(!null, "null is falsy");
assert(!undefined, "undefined is falsy");
assert(!NaN, "NaN is falsy");
assert(isNaN(NaN), "isNaN detects NaN");
assert(!!1, "1 is truthy");
assert(!!"hello", "non-empty string is truthy");
assert(!!{}, "object is truthy");
assert(!![], "array is truthy");

// == vs ===
assert(1 == "1", "== coerces string to number");
assert(1 !== "1", "=== no coercion");
assert(null == undefined, "== null/undefined");
assert(null !== undefined, "=== null/undefined differ");
assert(0 == "", "== 0/empty string");
assert(0 !== "", "=== 0/empty string differ");
assert(0 == false, "== 0/false");
assert(1 == true, "== 1/true");
assert("" == false, "== empty/false");

// Arithmetic coercion
assert("5" - 1 === 4, "string - number");
assert("5" + 1 === "51", "string + number = concat");
assert(true + true === 2, "bool + bool = number");
assert(null + 1 === 1, "null + 1 = 1");
assert(undefined + 1 !== undefined + 1, "undefined + 1 = NaN");

// parseInt/parseFloat coercion
assert(parseInt("42px") === 42, "parseInt stops at non-digit");
assert(parseFloat("3.14abc") === 3.14, "parseFloat stops at non-numeric");
assert(parseInt("") !== parseInt(""), "parseInt('') is NaN");

// Unary + and -
assert(+"42" === 42, "unary + converts string");
assert(+"abc" !== +"abc", "unary + NaN for non-numeric");
assert(-"5" === -5, "unary - converts string");

print("engine/type_coercion: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
