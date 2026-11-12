// Small callees that optimized code enters in register mode (OptGraph.reg_leaf): results of each
// representation, an argument the callee assigns, missing and wrong-typed arguments, and callee
// exits that make the caller run the call again from unchanged arguments.
function add(x, y) { return (x + y) | 0; }
function addf(x, y) { return x + y; }
function getx(o) { return o.x; }
function inc(x) { x = x + 1; return x; }
function sel(a, b) { if (a < b) return a; return b; }
function run(n, k) {
    var s = 0, t = 0.5, o = { x: 3 }, q = 0;
    for (var i = 0; i < n; i++) {
        s = add(s, i);
        t = addf(t, 0.25);
        q = (q + getx(o) + inc(i) + sel(i, 7)) | 0;
        if (i == k) o = { y: 1, x: "s" };
    }
    return [s, t, q, String(add("a", 1)), addf(1), getx({ x: [1] })];
}
var res;
for (var r = 0; r < 300; r++) res = run(1000, r == 250 ? 500 : -1);
var want = '[499500,250.5,510472,"0",null,[1]]';
if (JSON.stringify(res) != want) print("FAIL steady " + JSON.stringify(res));
res = run(1000, 10);
if (JSON.stringify(res) != '[499500,250.5,0,"0",null,[1]]') print("FAIL changed " + JSON.stringify(res));
print("jit_register_leaf: ok");
