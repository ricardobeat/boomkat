// Math calls in optimized code (OptOp.MATH): each function over ints, doubles, NaN, infinities and
// signed zeros must answer what the builtin answers. Sites see one callee until the end, when one
// is replaced (the callee guard exits) and one is given a string (the argument guard exits).
var out = [];
function show(label, v) { out.push(label + "=" + v); }
function fmt(v) { return Object.is(v, -0) ? "-0" : String(v); }

var doubles = [0, -0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 0.49999999999999994, 3.7, -3.7, 1e300, -1e300,
    Infinity, -Infinity, NaN, 2147483647.5, -2147483648.5, 1e-310, 7];
var ints = [0, 1, -1, 7, -7, 2147483647, -2147483647, -2147483648, 1000, -1000];

function unary(xs, n) {
    var acc = [];
    for (var r = 0; r < n; r++) {
        acc.length = 0;
        for (var i = 0; i < xs.length; i++) {
            var x = xs[i];
            acc.push(fmt(Math.abs(x)) + "," + fmt(Math.floor(x)) + "," + fmt(Math.ceil(x)) + "," + fmt(Math.round(x)) + "," +
                fmt(Math.sqrt(x)) + "," + fmt(Math.sin(x)) + "," + fmt(Math.cos(x)) + "," + fmt(Math.tan(x)) + "," +
                fmt(Math.exp(x)) + "," + fmt(Math.log(x)) + "," + fmt(Math.atan(x)));
        }
    }
    return acc.join(" ");
}
function binary(xs, ys, n) {
    var acc = [];
    for (var r = 0; r < n; r++) {
        acc.length = 0;
        for (var i = 0; i < xs.length; i++) {
            for (var j = 0; j < ys.length; j += 3) {
                var x = xs[i], y = ys[j];
                acc.push(fmt(Math.min(x, y)) + "," + fmt(Math.max(x, y)) + "," + fmt(Math.pow(x, y)) + "," + fmt(Math.atan2(x, y)));
            }
        }
    }
    return acc.join(" ");
}
// Int operands: abs, min and max stay integers; abs(-2^31) overflows into a double.
function intwork(xs, n) {
    var s = 0, t = 0;
    for (var r = 0; r < n; r++) {
        for (var i = 0; i < xs.length; i++) {
            var x = xs[i] | 0, y = xs[(i + 3) % xs.length] | 0;
            s = (s + Math.min(x, y) + Math.max(x, y) + Math.floor(x)) | 0;
            t += Math.abs(x);
        }
    }
    return s + ":" + t;
}
// A float loop where every value stays a double.
function norm(n) {
    var s = 0;
    for (var i = 1; i <= n; i++) {
        var a = i * 0.37, b = i * 1.13;
        s += Math.sqrt(a * a + b * b) + Math.floor(a) - Math.ceil(b) + Math.pow(a, 0.5) + Math.max(a, b) - Math.min(a, b);
    }
    return s;
}

var u = "", b = "", w = "", z = 0;
for (var k = 0; k < 120; k++) {
    u = unary(doubles, 2);
    b = binary(doubles, doubles, 1);
    w = intwork(ints, 3);
    z = norm(300);
}
show("unary", u);
show("binary", b);
show("int", w);
show("norm", z);
show("int-pos", intwork([1, 2, 3, 4, 5, 6], 50));

// The callee changes under a site that has only ever called Math.sqrt.
var realSqrt = Math.sqrt;
Math.sqrt = function (x) { return -x; };
show("replaced", norm(10));
Math.sqrt = realSqrt;
show("restored", norm(10));
// An argument that is no number: the builtin converts it.
show("string", unary(["4", "-0.5", "x", true, null, undefined], 1));

console.log(out.join("\n"));
