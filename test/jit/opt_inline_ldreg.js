// A heap value copied to a register of an inlined callee (`var o = arr; o[i] = v`, `var o = this.data`):
// the copy lives only in a machine register, element stores and reads take the receiver from it, a
// store that needs the counted path or any other receiver kind leaves for the baseline code.
var out = [];
function show(label, v) { out.push(label + "=" + (Object.is(v, -0) ? "-0" : String(v))); }

function setnum(arr, i) { var o = arr; o[i] = 7; return i; }
function setany(arr, i, v) { var o = arr; o[i] = v; return i; }
function getnum(arr, i) { var o = arr; return o[i] | 0; }
function twice(arr, i) { var o = arr; o[i] = 1; o[i + 1] = 2; return o[i] + o[i + 1]; }
function alias(arr) { var o = arr; var p = o; return p; }
function Holder(d) { this.data = d; }
Holder.prototype.put = function (i, v) { var d = this.data; d[i] = v; return i; };
Holder.prototype.get = function (i) { var d = this.data; return d[i] | 0; };
Holder.prototype.sum = function () { var d = this.data; return d[0] + d[1] + d[2]; };

function caller(a, h, i, v) {
    var t = 0.5;
    t += setnum(a, i % 4);
    t += setany(a, (i + 1) % 4, v);
    t += getnum(a, i % 4);
    t += twice(a, i % 3);
    t += alias(a).length;
    t += h.put(i % 4, v === v ? 3 : 4);
    t += h.get(i % 4);
    t += h.sum();
    return t;
}
var a = [0, 0, 0, 0], h = new Holder([1, 2, 3, 4]);
var acc = 0;
for (var i = 0; i < 6000; i++) acc += caller(a, h, i, i & 7);
show("warm", acc + "|" + a.join() + "|" + h.data.join());

// Receivers and values of every kind through the same sites.
var kinds = [[1, 2, 3, 4], new Float64Array(4), new Int32Array(4), { 0: 1, 1: 2, 2: 3, 3: 4, length: 4 }, "abcd", [1, , 3, 4], Object.freeze([1, 2, 3, 4]), [1.5, 2.5, 3.5, 4.5]];
var vals = [5, 0.5, "s", { z: 1 }, [9], null, undefined, true, -0, NaN];
for (var k = 0; k < kinds.length; k++) {
    for (var j = 0; j < vals.length; j++) {
        var arr = kinds[k];
        var snapshot = Array.prototype.map.call(arr, function (e) { return e; });
        var r;
        try { r = caller(kinds[k] === arr ? (typeof arr === "string" ? [1, 2, 3, 4] : arr) : arr, new Holder(arr), 1, vals[j]); } catch (e) { r = "throws " + e.name; }
        show("k" + k + "v" + j, r + "|" + Array.prototype.map.call(arr, function (e) { return typeof e === "object" ? "o" : String(e); }).join());
    }
}

// Holder whose data changes kind between calls.
var h2 = new Holder([1, 2, 3, 4]);
for (var i = 0; i < 3000; i++) h2.put(i & 3, i);
h2.data = new Float64Array(4);
show("typed", h2.put(2, 1.5) + "|" + h2.get(2) + "|" + h2.sum());
h2.data = { 0: 1, 1: 2, 2: 3 };
show("plain", h2.put(1, 8) + "|" + h2.get(1) + "|" + h2.sum());
h2.data = null;
try { h2.put(0, 1); } catch (e) { show("null", e.name); }
h2.data = [1, 2, 3];
Object.defineProperty(Array.prototype, 5, { set: function (v) { out.push("setter " + v); }, configurable: true });
h2.put(5, 1); h2.put(3, 2);
delete Array.prototype[5];
show("setter", h2.data.join());

// Counted stores of strings and objects over strings and objects, with allocation pressure.
var hh = new Holder(["a", "b", {}, "d"]);
var keep = [];
for (var i = 0; i < 20000; i++) {
    hh.put(i & 3, (i & 1) ? "s" + i : { n: i });
    keep[i & 31] = [i, "x" + i];
}
show("counted", hh.data.map(function (e) { return typeof e === "object" ? "o" + e.n : e; }).join());

print(out.join("\n"));
