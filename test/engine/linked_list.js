// Linked list
// Demonstrates node-based list operations.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function List() { this.head = null; this.tail = null; this.length = 0; }
function Node(value) { this.value = value; this.next = null; }

List.prototype.push = function (v) {
    var n = new Node(v);
    if (this.tail) this.tail.next = n;
    else this.head = n;
    this.tail = n;
    this.length++;
};

List.prototype.shift = function () {
    if (!this.head) return undefined;
    var v = this.head.value;
    this.head = this.head.next;
    if (!this.head) this.tail = null;
    this.length--;
    return v;
};

List.prototype.toArray = function () {
    var out = [], cur = this.head;
    while (cur) { out.push(cur.value); cur = cur.next; }
    return out;
};

var list = new List();
assert(list.length === 0, "empty length");
assert(list.head === null, "empty head");

list.push("a");
list.push("b");
list.push("c");

assert(list.length === 3, "length 3");
assert(list.head.value === "a", "head a");
assert(list.tail.value === "c", "tail c");

assert(JSON.stringify(list.toArray()) === '["a","b","c"]', "toArray");

assert(list.shift() === "a", "shift a");
assert(list.shift() === "b", "shift b");
assert(list.length === 1, "length 1 after shifts");

// Linked list: reverse
function reverseLL(head) {
    var prev = null, cur = head;
    while (cur) {
        var nxt = cur.next;
        cur.next = prev;
        prev = cur;
        cur = nxt;
    }
    return prev;
}

var l2 = new List();
for (var i = 1; i <= 4; i++) l2.push(i);
l2.head = reverseLL(l2.head);
assert(JSON.stringify(l2.toArray()) === "[4,3,2,1]", "reverseLL");

print("engine/linked_list: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");