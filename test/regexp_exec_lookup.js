// RegExp.prototype.test and the @@-methods call RegExpExec, which reads `exec`
// from the receiver. A plain RegExp inheriting the intrinsic skips the lookup
// (regexp_inherits_exec); everything else must still see its own `exec`.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function run(rx, s) {
    var t = 0;
    for (var i = 0; i < 300; i++) t += rx.test(s) ? 1 : 0;
    return t;
}

check("plain", run(/b+/, "abbc"), 300);

var own = /b+/;
var ownCalls = 0;
own.exec = function (s) { ownCalls++; return null; };
check("own exec result", run(own, "abbc"), 0);
check("own exec calls", ownCalls, 300);

class Sub extends RegExp {
    exec(s) { this.seen = (this.seen || 0) + 1; return super.exec(s); }
}
var sub = new Sub("b+");
check("subclass result", run(sub, "abbc"), 300);
check("subclass calls", sub.seen, 300);

var protoCalls = 0;
var exec = RegExp.prototype.exec;
RegExp.prototype.exec = function (s) { protoCalls++; return exec.call(this, s); };
check("replaced proto exec result", run(/b+/, "abbc"), 300);
check("replaced proto exec calls", protoCalls, 300);
RegExp.prototype.exec = exec;
check("restored", run(/b+/, "abbc"), 300);

// A getter for exec runs once per call.
var getterCalls = 0;
Object.defineProperty(RegExp.prototype, "exec", {
    get: function () { getterCalls++; return exec; }, configurable: true,
});
check("getter result", run(/b+/, "abbc"), 300);
check("getter calls", getterCalls, 300);
Object.defineProperty(RegExp.prototype, "exec", { value: exec, writable: true, configurable: true });
check("data again", run(/b+/, "abbc"), 300);

// A non-RegExp with the same own property and prototype is not a RegExp.
var fake = Object.create(RegExp.prototype);
Object.defineProperty(fake, "lastIndex", { value: 0, writable: true });
var threw = false;
try { RegExp.prototype.test.call(fake, "abbc"); } catch (e) { threw = e instanceof TypeError; }
check("fake receiver throws", threw, true);

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
