// Native calls under allocation pressure: callees allocate and return objects
// and strings while the collector runs, so frames published and popped by the
// baseline's call entry and return subroutine must keep every live value
// reachable. Results match the interpreter.
function node(v, next) { return { v: v, next: next }; }
function build(n) { var h = null; for (var i = 0; i < n; i++) h = node(i, h); return h; }
function sum(h) { var s = 0; while (h !== null) { s += h.v; h = h.next; } return s; }
function label(i) { var t = "n" + i; return t + ":" + (i & 7); }
function pair(a, b) { var p = [a, b]; return p; }
function churn(i) { var tmp = []; for (var k = 0; k < 8; k++) tmp.push({ k: k, s: label(k + i) }); return tmp[i & 7].s; }

var keep = [];
var total = 0, chars = 0;
for (var i = 0; i < 4000; i++) {
    var h = build(i & 31);
    total += sum(h);
    var p = pair(node(i, null), label(i));
    if (p[0].v !== i) throw new Error("lost object " + i);
    chars += p[1].length + churn(i).length;
    if ((i & 63) === 0) keep.push(p);
}
var kept = 0;
for (var j = 0; j < keep.length; j++) kept += keep[j][0].v + keep[j][1].length;
print(total + " " + chars + " " + kept);
