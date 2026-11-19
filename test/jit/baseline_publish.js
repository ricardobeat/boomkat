// Register stores of baseline reads (Asm.publish): objects, numbers, strings fresh and
// interned, BigInts and symbols through LDREG, GETPROPC and GETTHISC, a read into its own
// receiver's register, and enough garbage that some of it runs while the collector marks.
var out = [];
function log(x) { out.push(String(x)); }

function Node(v, next) { this.v = v; this.next = next; this.s = "s" + v; this.big = BigInt(v); }
Node.prototype.label = function () { var s = this.s; var b = this.big; var v = this.v; return s + ":" + b + ":" + v; };

var list = null;
for (var i = 0; i < 50; i++) list = new Node(i, list);

// o = o.next reads into the receiver's own register.
function walk(o) { var n = 0; while (o !== null) { n += o.v; o = o.next; } return n; }
// A string, a BigInt and an object through GETPROPC, then LDREG copies of each.
function gather(o) {
    var acc = "", total = 0n, last = null;
    while (o !== null) {
        var s = o.s, b = o.big, nx = o.next;
        var s2 = s, b2 = b, o2 = nx;
        acc += s2[0]; total += b2; last = o2 === null ? o : last;
        o = nx;
    }
    return acc.length + ":" + total + ":" + (last === null ? "-" : last.v);
}

var keep = [];
for (var round = 0; round < 60; round++) {
    var r1 = walk(list), r2 = gather(list), r3 = list.label();
    // Fresh strings and objects for the collector to find while these loops run.
    for (var k = 0; k < 200; k++) keep[k % 50] = { t: "x" + round + "_" + k, n: [k, round] };
    if (round % 20 === 0) log(r1 + " " + r2 + " " + r3);
}

// A symbol and an interned string read through a cached site.
var sym = Symbol("tag");
var holder = { sym: sym, name: "interned" };
function readSym(h) { var s = h.sym; var t = s; return t; }
function readName(h) { var s = h.name; var t = s; return t; }
var same = 0;
for (var i = 0; i < 300; i++) same += (readSym(holder) === sym ? 1 : 0) + (readName(holder) === "interned" ? 1 : 0);
log(same);

// Strings built per iteration and published through GETTHISC.
class Word {
    constructor(i) { this.text = "w" + i + "-" + (i * 7); }
    get() { var t = this.text; return t; }
}
var joined = 0;
for (var i = 0; i < 2000; i++) joined += new Word(i).get().length;
log(joined);
log(keep.length + " " + keep[49].t);

print(out.join("\n"));
