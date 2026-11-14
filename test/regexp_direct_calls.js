// RegExp.prototype.exec and test called from hot loops on plain RegExps, which
// compiled code runs without the builtin's frame, and every case that must
// leave that route: a changed prototype, an odd lastIndex, sticky and global
// receivers, subclasses, an own exec, non-string arguments and a throwing
// toString. Each loop runs long enough to be compiled.
var failures = 0;
function check(what, got, want) {
    if (got !== want) {
        failures++;
        console.log("FAIL " + what + ": got " + got + ", want " + want);
    }
}

var N = 3000;
var s = "id=4711; name=box; size=12";

function execLoop(r, arg, n) {
    var t = 0;
    for (var i = 0; i < n; i++) {
        var m = r.exec(arg);
        t += m === null ? -1 : m[0].length + m.index;
    }
    return t;
}

function testLoop(r, arg, n) {
    var t = 0;
    for (var i = 0; i < n; i++) if (r.test(arg)) t++;
    return t;
}

check("exec match", execLoop(/(\w+)=(\d+)/, s, N), N * 7);
check("exec fail", execLoop(/zzz(\d+)/, s, N), -N);
check("test match", testLoop(/(\w+)=(\d+)/, s, N), N);
check("test fail", testLoop(/q+/, s, N), 0);

// Global and sticky receivers advance lastIndex and wrap around.
function globalLoop(n) {
    var r = /\d+/g, out = [];
    for (var i = 0; i < n; i++) {
        var m = r.exec(s);
        if (i < 4) out.push(m === null ? "null:" + r.lastIndex : m[0] + ":" + r.lastIndex);
    }
    return out.join(",");
}
check("global exec", globalLoop(N), "4711:7,12:26,null:0,4711:7");

function stickyLoop(n) {
    var r = /\w+=/y, out = [];
    for (var i = 0; i < n; i++) {
        var ok = r.test(s);
        if (i < 3) out.push(ok + ":" + r.lastIndex);
    }
    return out.join(",");
}
check("sticky test", stickyLoop(N), "true:3,false:0,true:3");

function stickyGlobalLoop(n) {
    var r = /\d/gy, count = 0;
    r.lastIndex = 3;
    for (var i = 0; i < n; i++) if (r.exec(s) !== null) count++;
    return count + ":" + r.lastIndex;
}
check("sticky global", stickyGlobalLoop(N), "4:0");

// lastIndex out of range, non-integer, or an object whose valueOf runs.
function lastIndexLoop(n) {
    var r = /\d+/g, t = 0, calls = 0;
    for (var i = 0; i < n; i++) {
        if (i % 3 === 0) r.lastIndex = 100;
        else if (i % 3 === 1) r.lastIndex = 1.5;
        else r.lastIndex = { valueOf: function () { calls++; return 20; } };
        var m = r.exec(s);
        t += m === null ? 0 : m[0].length;
    }
    return t + ":" + calls;
}
check("lastIndex values", lastIndexLoop(N), (N / 3 * 4 + N / 3 * 2) + ":" + N / 3);

// A non-writable lastIndex on a global receiver throws when exec writes it.
function frozenLastIndex(n) {
    var r = /\d/g, caught = 0;
    Object.defineProperty(r, "lastIndex", { writable: false, value: 0 });
    for (var i = 0; i < n; i++) {
        try { r.exec(s); } catch (e) { if (e instanceof TypeError) caught++; }
    }
    return caught;
}
check("frozen lastIndex", frozenLastIndex(N), N);

// Arguments that are not strings are converted, and a throwing toString throws.
function argsLoop(n) {
    var r = /\d+/, t = 0, thrown = 0;
    var obj = { toString: function () { return "ab123"; } };
    var bad = { toString: function () { throw new RangeError("no"); } };
    for (var i = 0; i < n; i++) {
        var k = i % 5;
        try {
            var m = k === 0 ? r.exec(4711) : k === 1 ? r.exec(obj) : k === 2 ? r.exec(bad)
                : k === 3 ? r.exec() : r.exec(Symbol("x"));
            t += m === null ? 100 : m[0].length;
        } catch (e) {
            if (e instanceof RangeError) thrown++;
            else if (e instanceof TypeError) thrown += 1000;
        }
    }
    return t + ":" + thrown;
}
check("arguments", argsLoop(N), (N / 5 * (4 + 3 + 100)) + ":" + (N / 5 * 1001));

// An own exec on the receiver, and a subclass overriding exec: test calls them.
function ownExec(n) {
    var r = /\d+/, calls = 0;
    r.exec = function (str) { calls++; return null; };
    var hits = testLoop(r, s, n);
    return hits + ":" + calls;
}
check("own exec", ownExec(N), "0:" + N);

class Sub extends RegExp {
    exec(str) { this.seen = (this.seen | 0) + 1; return super.exec(str); }
}
function subclassLoop(n) {
    var r = new Sub("\\d+");
    var e = execLoop(r, s, n), t = testLoop(r, s, n);
    return e + ":" + t + ":" + r.seen;
}
check("subclass", subclassLoop(N), (N * 7) + ":" + N + ":" + (2 * N));

// RegExp.prototype.exec replaced mid-loop and restored: test follows it.
function protoSwap(n) {
    var r = /\d+/, t = 0;
    var exec = RegExp.prototype.exec;
    for (var i = 0; i < n; i++) {
        if (i === n / 2) RegExp.prototype.exec = function () { return null; };
        if (r.test(s)) t++;
    }
    RegExp.prototype.exec = exec;
    for (var j = 0; j < n; j++) if (r.test(s)) t++;
    return t;
}
check("prototype exec swap", protoSwap(N), N / 2 + N);

// A receiver that is not a RegExp throws from exec, and test reaches an exec
// found through the prototype chain.
function receivers(n) {
    var thrown = 0, hits = 0;
    var exec = RegExp.prototype.exec, test = RegExp.prototype.test;
    var fake = { exec: function () { return {}; } };
    for (var i = 0; i < n; i++) {
        try { exec.call(fake, s); } catch (e) { if (e instanceof TypeError) thrown++; }
        if (test.call(fake, s)) hits++;
    }
    return thrown + ":" + hits;
}
check("receivers", receivers(N), N + ":" + N);

// Wide subjects and captures that do not participate.
function wideLoop(n) {
    var r = /(a)|(ā+)/, t = 0;
    for (var i = 0; i < n; i++) {
        var m = r.exec("xxāāy");
        t += (m[1] === undefined ? 1 : 0) + m[2].length + m.index;
    }
    return t;
}
check("wide subject", wideLoop(N), N * 5);

// A literal's test (RETEST) with a Symbol argument throws like any other.
function literalSymbol(n) {
    var thrown = 0;
    for (var i = 0; i < n; i++) {
        try { /a/.test(i % 100 === 7 ? Symbol() : "a"); } catch (e) { if (e instanceof TypeError) thrown++; }
    }
    return thrown;
}
check("literal test of a Symbol", literalSymbol(N), Math.floor((N + 92) / 100));

if (failures === 0) console.log("regexp direct calls: ok");
