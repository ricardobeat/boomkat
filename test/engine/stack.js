// Stack
// Demonstrates LIFO semantics via push/pop/peek.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function Stack() { this.items = []; }
Stack.prototype.push = function (v) { this.items.push(v); };
Stack.prototype.pop = function () { return this.items.pop(); };
Stack.prototype.peek = function () { return this.items[this.items.length - 1]; };
Stack.prototype.size = function () { return this.items.length; };
Stack.prototype.isEmpty = function () { return this.items.length === 0; };

var s = new Stack();
assert(s.isEmpty(), "new stack empty");
assert(s.size() === 0, "size 0");

s.push("a");
s.push("b");
s.push("c");
assert(s.size() === 3, "size after pushes");
assert(s.peek() === "c", "peek top");

assert(s.pop() === "c", "pop c");
assert(s.pop() === "b", "pop b");
assert(s.peek() === "a", "peek after pops");
assert(s.size() === 1, "size after pops");

// Reverse a string via stack
function reverse(str) {
    var st = new Stack();
    for (var i = 0; i < str.length; i++) st.push(str[i]);
    var out = "";
    for (var i = st.size() - 1; i >= 0; i--) out += st.items[i];
    return out;
}

assert(reverse("") === "", "reverse empty");
assert(reverse("a") === "a", "reverse single");
assert(reverse("hello") === "olleh", "reverse hello");
assert(reverse("abcba") === "abcba", "reverse palindrome");

print("engine/stack: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");