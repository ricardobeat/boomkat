// Property writes inside inlined helpers, in the shapes a compiler sees.
var failures = 0;
function check(label, actual, expected) {
    if (actual !== expected) {
        print("FAIL " + label + ": got " + actual + ", expected " + expected);
        failures++;
    }
}

function Node() { this.n = 0; this.tag = "t"; this.child = null; }
Node.prototype.setN = function (v) { this.n = v; return v; };
Node.prototype.bump = function () { this.n = this.n + 1; return this.n; };
Node.prototype.setTag = function (v) { this.tag = v; return v; };
Node.prototype.swap = function (o) { var t = this.n; this.n = o.n; o.n = t; return this.n; };
Node.prototype.clear = function () { this.n = 0; this.tag = ""; return this.n; };
Node.prototype.setChild = function (c) { this.child = c; return c; };

function Holder() { this.node = new Node(); }
Holder.prototype.setNodeN = function (v) { this.node.n = v; return v; };
Holder.prototype.getNodeN = function () { return this.node.n; };

var node = new Node();
var other = new Node();
var holder = new Holder();

for (var round = 0; round < 500; round++) {
    node.setN(round);
    check("setN", node.n, round);
    node.bump();
    check("bump", node.n, round + 1);
    node.setTag("x" + round);
    check("setTag", node.tag, "x" + round);
    var before = node.n;
    var otherBefore = other.n;
    node.swap(other);
    check("swap node", node.n, otherBefore);
    check("swap other", other.n, before);
    node.clear();
    check("clear n", node.n, 0);
    check("clear tag", node.tag, "");
    holder.setNodeN(round);
    check("nested write", holder.getNodeN(), round);
    holder.node.setChild(node);
    check("child", holder.node.child === node, true);
}

if (failures == 0) print("ok");
