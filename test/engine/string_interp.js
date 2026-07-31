// String interpolation
// Demonstrates building strings by concatenation vs. array.join.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

var name = "World";
var count = 3;
var price = 1.50;

// Concat
var s1 = "Hello, " + name + "!";
assert(s1 === "Hello, World!", "concat interpolation");

// Many parts: use array.join to avoid quadratic concat
var parts = [];
for (var i = 0; i < count; i++) parts.push("item" + i);
var s2 = parts.join(", ");
assert(s2 === "item0, item1, item2", "join build");

// printf-style with helper
function sprintf(fmt, a, b, c) {
    var i = 0;
    var args = [a, b, c];
    return fmt.replace(/%[sd]/g, function (_) {
        var v = args[i++];
        return v === undefined ? "" : String(v);
    });
}

assert(sprintf("%s costs $%s", "Coffee", "3.50") === "Coffee costs $3.50", "sprintf basic");
assert(sprintf("[%s/%s/%s]", 1, 2, 3) === "[1/2/3]", "sprintf numbers");

// Template using array + join (a poor man's tagged-template)
function tpl(strings, values) {
    var out = strings[0];
    for (var i = 0; i < values.length; i++) {
        out += values[i] + strings[i + 1];
    }
    return out;
}

// strings has one more entry than values; expected output is
// segments[0] + values[0] + segments[1] + values[1] + segments[2]
var greet = tpl(["Hello, ", "! You're ", "."], ["Alice", 25]);
assert(greet === "Hello, Alice! You're 25.", "tpl tagged");

print("engine/string_interp: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");