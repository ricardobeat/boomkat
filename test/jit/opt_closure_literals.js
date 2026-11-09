// Functions that build closures, regexp literals, environment cells and array literals, which the
// optimizing tier used to refuse as a whole: each instruction is a GENERIC node now, so the rest of
// the body is compiled and the literals still answer what they did.
var out = [];
function show(label, v) { out.push(label + "=" + String(v)); }

function counter(start) {
    var n = start;
    return {
        add: function (k) { n = n + k; return n; },
        get: function () { return n; },
        set: function (k) { n = k; return n; }
    };
}
function withRegex() {
    var re = /(\w+)-(\d+)/;
    var total = 0;
    for (var i = 0; i < 500; i++) {
        var m = re.exec("item-" + (i % 10));
        if (m) total += m[2].length + m[1].length;
    }
    return total + re.source.length + re.global;
}
function withArray(n) {
    var acc = 0;
    for (var i = 0; i < 400; i++) {
        var a = [i, i + 1, "s" + (i % 3)];
        acc += a[0] + a[1] + a[2].length;
    }
    return acc + n;
}
function loopClosures(n) {
    var fns = [];
    for (var i = 0; i < n; i++) fns.push(function () { return i; });
    var sum = 0;
    for (var k = 0; k < fns.length; k++) sum += fns[k]();
    return sum;
}

var s = 0;
for (var i = 0; i < 3000; i++) {
    var c = counter(i % 5);
    c.add(i % 7); c.set(i % 11);
    s += c.get();
}
show("counter", s);
show("regex", withRegex());
show("array", withArray(3));
show("closures", loopClosures(30));

// A cell shared by a closure that outlives the call.
var keep = counter(10);
keep.add(5);
var snap1 = keep.get();
for (var i = 0; i < 4000; i++) keep.add(1);
show("keep", snap1 + ":" + keep.get());

// The literals a refused body used to leave alone are still those of the interpreter.
var re = /a(b*)c/gi;
re.lastIndex = 0;
var m = re.exec("xxabbbcyyac");
show("exec", m ? m[0] + ":" + m[1] + ":" + re.lastIndex : "null");
show("source", re.source + ":" + re.flags);
var arr = [1, , 3, "x"];
show("holes", arr.length + ":" + (1 in arr) + ":" + arr[3]);
show("cls", typeof (function () { return function inner() { return 1; }; })());

print(out.join("\n"));
