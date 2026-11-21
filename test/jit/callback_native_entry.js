// Callbacks a builtin calls (sort comparators, replace functions, Array.from's map, a JSON reviver,
// Map.prototype.forEach) whose bodies are long enough to run their baseline code from the host call
// (vm_run_native): each is warmed up past compilation, and then made to throw, allocate under
// collection, call into JS, nest another host call, or meet something its code leaves to the
// interpreter.
var out = [];
function log(x) { out.push(String(x)); }

function item(i) {
    return { id: i, groupOrder: i % 2, renderOrder: (i * 3) % 4, material: { id: i % 5 }, z: (i * 7919) % 101 };
}
function painter(a, b) {
    if (a.groupOrder !== b.groupOrder) return a.groupOrder - b.groupOrder;
    else if (a.renderOrder !== b.renderOrder) return a.renderOrder - b.renderOrder;
    else if (a.material.id !== b.material.id) return a.material.id - b.material.id;
    else if (a.z !== b.z) return a.z - b.z;
    else return a.id - b.id;
}
var items = [];
for (var i = 0; i < 120; i++) items.push(item(i));
function ids(a) { var s = ""; for (var i = 0; i < a.length; i += 17) s += a[i].id + ","; return s; }

var h = 0;
for (var r = 0; r < 40; r++) { var a = items.slice(); a.sort(painter); h = (h * 31 + a[r % 120].id) | 0; }
log(h + " " + ids(items.slice().sort(painter)));

// A comparator that throws partway, once it has native code.
var limit = -1, calls = 0;
function throwing(a, b) {
    if (++calls === limit) throw new Error("cmp " + calls);
    if (a.groupOrder !== b.groupOrder) return a.groupOrder - b.groupOrder;
    if (a.renderOrder !== b.renderOrder) return a.renderOrder - b.renderOrder;
    if (a.material.id !== b.material.id) return a.material.id - b.material.id;
    return a.id - b.id;
}
for (var r = 0; r < 10; r++) items.slice().sort(throwing);
calls = 0; limit = 300;
try { items.slice().sort(throwing); log("no throw"); } catch (e) { log(e.message); }
limit = -1;

// Allocation in the comparator, with the collector running underneath the sort.
function allocating(a, b) {
    var t = [a.z, b.z, { k: a.id }, { k: b.id }];
    var u = { s: "" + t[2].k + "/" + t[3].k };
    if (t[0] !== t[1]) return t[0] - t[1];
    if (a.material.id !== b.material.id) return a.material.id - b.material.id;
    return u.s.length - 3 + (t[2].k - t[3].k);
}
var keep = [];
for (var r = 0; r < 30; r++) { var a = items.slice(); a.sort(allocating); keep.push(a[r]); }
log(ids(items.slice().sort(allocating)) + " " + keep.length);

// A comparator that calls JS functions, and one that sorts again inside itself.
function key(o) { return o.z * 1000 + o.id; }
function viaCall(a, b) {
    var ka = key(a), kb = key(b);
    if (a.groupOrder !== b.groupOrder) return a.groupOrder - b.groupOrder;
    if (ka !== kb) return ka - kb;
    return a.id - b.id;
}
// The nested sorts run once per outer sort, so that the count is not the sort's choice of pairs.
var depth = 0, inner = 0, done = false;
function nested(a, b) {
    if (!done && depth < 1) {
        done = true;
        depth++;
        inner += [3, 1, 2, 5, 4].sort(function (x, y) { return y - x; })[0];
        inner += items.slice(0, 20).sort(painter)[0].id;
        depth--;
    }
    if (a.renderOrder !== b.renderOrder) return a.renderOrder - b.renderOrder;
    if (a.z !== b.z) return a.z - b.z;
    return a.id - b.id;
}
for (var r = 0; r < 20; r++) { items.slice().sort(viaCall); done = false; items.slice().sort(nested); }
done = false;
log(ids(items.slice().sort(viaCall)) + " " + ids(items.slice().sort(nested)) + " " + inner);

// A comparator whose body the baseline leaves to the interpreter partway (a with scope, eval).
function sloppy(a, b) {
    var o = { w: a.z - b.z };
    with (o) { if (w !== 0) return w; }
    if (a.material.id !== b.material.id) return a.material.id - b.material.id;
    return eval("a.id - b.id");
}
for (var r = 0; r < 10; r++) items.slice().sort(sloppy);
log(ids(items.slice().sort(sloppy)));

// Values a comparator returns that sort must convert, and a receiver it reads.
function valued(a, b) {
    var d = a.z - b.z;
    if (d === 0) d = a.id - b.id;
    if (a.groupOrder === 0 && b.groupOrder === 0) return { valueOf: function () { return d; } };
    if (a.renderOrder === b.renderOrder) return String(d);
    return d;
}
for (var r = 0; r < 10; r++) items.slice().sort(valued);
log(ids(items.slice().sort(valued)));
var bad = null;
function badValue(a, b) {
    if (bad !== null && a.id === 5) return bad;
    if (a.z !== b.z) return a.z - b.z;
    if (a.material.id !== b.material.id) return a.material.id - b.material.id;
    return a.id - b.id;
}
for (var r = 0; r < 10; r++) items.slice().sort(badValue);
bad = { valueOf: function () { throw new RangeError("valueOf"); } };
try { items.slice().sort(badValue); log("no throw"); } catch (e) { log(e.name + " " + e.message); }
bad = Symbol("s");
try { items.slice().sort(badValue); log("no throw"); } catch (e) { log(e.name); }
bad = NaN;
log(items.slice(0, 10).sort(badValue).length);

// Other builtins that call back.
function mapper(o, i) {
    if (o.groupOrder === 1 && o.renderOrder > 1) return o.z * 2 + i;
    if (o.material.id === 3) return -o.id;
    return o.renderOrder * 100 + o.material.id * 10 + o.groupOrder;
}
var m = 0;
for (var r = 0; r < 40; r++) m += Array.from(items, mapper).length;
log(m + " " + Array.from(items, mapper).slice(0, 12).join(","));
function replacer(all, a, b, off) {
    var x = Number(a), y = Number(b);
    if (x > y) return "[" + (x - y) + "]";
    if (x === y) return "=" + off;
    return all.length > 3 ? all.toUpperCase() : "<" + all + ">";
}
var text = "";
for (var i = 0; i < 60; i++) text += (i % 7) + "-" + (i % 5) + " ";
var rr = "";
for (var r = 0; r < 40; r++) rr = text.replace(/(\d)-(\d)/g, replacer);
log(rr.slice(0, 80));
function reviver(k, v) {
    if (typeof v === "number" && k !== "id") return v * 2 + (k.length > 2 ? 1 : 0);
    if (v && typeof v === "object" && !Array.isArray(v) && v.id !== undefined) v.seen = true;
    return v;
}
var json = JSON.stringify(items.slice(0, 30)), parsed;
for (var r = 0; r < 20; r++) parsed = JSON.parse(json, reviver);
log(parsed[7].z + " " + parsed[7].material.id + " " + parsed[29].seen);
var map = new Map();
for (var i = 0; i < 50; i++) map.set("k" + i, items[i]);
var acc = 0;
function visit(v, k, mm) {
    if (v.groupOrder === 0 && mm.size > 10) acc += v.z;
    else if (k.length > 2) acc -= v.material.id;
    else acc += v.renderOrder * 3 + v.id;
}
for (var r = 0; r < 20; r++) map.forEach(visit);
log(acc);

// Deep recursion through native callbacks.
function rec(a, b) {
    if (a.id === 0 && rdepth < 300) { rdepth++; [items[1], items[0]].sort(rec); rdepth--; }
    if (a.z !== b.z) return a.z - b.z;
    if (a.material.id !== b.material.id) return a.material.id - b.material.id;
    return a.id - b.id;
}
var rdepth = 0;
for (var r = 0; r < 5; r++) items.slice(0, 30).sort(rec);
rdepth = 0;
log(ids(items.slice(0, 60).sort(rec)));

print(out.join("\n"));
