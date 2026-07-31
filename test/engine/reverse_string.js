// String reversal

function reverseString(s) {
    var r = "";
    for (var i = s.length - 1; i >= 0; i--) r += s.charAt(i);
    return r;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(reverseString("") === "", "reverse empty");
assert(reverseString("a") === "a", "reverse 'a'");
assert(reverseString("hello") === "olleh", "reverse 'hello'");
assert(reverseString("racecar") === "racecar", "reverse palindrome");
assert(reverseString("abc 123") === "321 cba", "reverse with spaces/digits");
assert(reverseString("stressed") === "desserts", "reverse 'stressed'");

print("engine/reverse_string: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
