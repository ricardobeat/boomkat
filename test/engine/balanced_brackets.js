// Balanced brackets
// Check that a string of brackets is properly nested.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function isBalanced(s) {
    var stack = [];
    for (var i = 0; i < s.length; i++) {
        var ch = s[i];
        if (ch === "(" || ch === "[" || ch === "{") {
            stack.push(ch);
        } else if (ch === ")" || ch === "]" || ch === "}") {
            if (stack.length === 0) return false;
            var top = stack.pop();
            if (ch === ")" && top !== "(") return false;
            if (ch === "]" && top !== "[") return false;
            if (ch === "}" && top !== "{") return false;
        }
    }
    return stack.length === 0;
}

assert(isBalanced(""), "empty");
assert(isBalanced("()"), "()");
assert(isBalanced("()[]{}"), "()[]{}");
assert(isBalanced("([{}])"), "([{}])");
assert(isBalanced("([])"), "([])");
assert(isBalanced("{[()]}"), "{[()]}");

assert(!isBalanced("("), "just (");
assert(!isBalanced(")"), "just )");
assert(!isBalanced("(]"), "(]");
assert(!isBalanced("([)]"), "([)]");
assert(!isBalanced("(("), "((");
assert(!isBalanced(")("), ")(");

// Generate balanced strings of length 2n
function gen(n) {
    var out = [];
    function rec(s, opens) {
        if (s.length === 2 * n) {
            if (opens === 0) out.push(s);
            return;
        }
        if (opens < n) rec(s + "(", opens + 1);
        if (opens > 0) rec(s + ")", opens - 1);
    }
    rec("", 0);
    return out;
}

var cat4 = gen(2);
assert(cat4.length === 2, "cat(2) = 2 strings");
assert(cat4.indexOf("(())") !== -1 && cat4.indexOf("()()") !== -1, "cat(2) contents");

var cat6 = gen(3);
assert(cat6.length === 5, "cat(3) = 5 (Catalan)");
for (var i = 0; i < cat6.length; i++) assert(isBalanced(cat6[i]), "gen balanced " + cat6[i]);

print("engine/balanced_brackets: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");