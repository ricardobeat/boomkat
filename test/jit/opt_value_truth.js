// The truth of a VALUE node (a field read) tested in its register: `if`, `!`, `?:` and `&&` over
// objects, strings empty or not, undefined, null, zeros, NaN, doubles, booleans, symbols and a
// BigInt (which leaves through the slow path), in the root body and in an inlined one.
function Box(v) { this.v = v; this.w = 1; }
var vals = [{}, "", "s", undefined, null, 0, -0, NaN, 1.5, 0.0, true, false, Symbol("q"), [], 7];
if (typeof BigInt == "function") { vals.push(BigInt(0)); vals.push(BigInt(3)); }
var boxes = vals.map(function (v) { return new Box(v); });
function test(b) { return b.v ? 1 : 2; }
function not(b) { return !b.v; }
function both(b) { return b.v && b.w; }
function branch(b) { var n = 0; if (b.v) n += 4; if (!b.v) n += 8; return n; }
function inl(b) { return test(b) + (not(b) ? 16 : 32) + branch(b); }
var sum = 0, trace = "";
for (var i = 0; i < 30000; i++) {
    // Objects and strings first, so that the code is built for them; then everything.
    var b = i < 15000 ? boxes[i % 3] : boxes[i % boxes.length];
    var x = test(b) + (not(b) ? 64 : 128) + (both(b) ? 256 : 512) + branch(b) + inl(b);
    sum = (sum + x) | 0;
    if (i >= 29985) trace += x + ",";
}
print(sum, trace);
