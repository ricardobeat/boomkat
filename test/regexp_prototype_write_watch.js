// Every way of changing RegExp.prototype while the string and RegExp methods
// run hot, each undone again: the fast paths must see the change at once and
// resume once the intrinsics are back.
var failures = 0;
function check(got, want, what) {
    if (got !== want) { failures++; print("FAIL " + what + ": got " + got + ", want " + want); }
}

var P = RegExp.prototype;
var origExec = P.exec, origTest = P.test, origReplace = P[Symbol.replace];
var origMatch = P[Symbol.match], origSplit = P[Symbol.split], origSearch = P[Symbol.search];
var flagsDesc = Object.getOwnPropertyDescriptor(P, "flags");
var globalDesc = Object.getOwnPropertyDescriptor(P, "global");
var origProto = Object.getPrototypeOf(P);

function run(tag) {
    var out = [];
    for (var i = 0; i < 200; i++) {
        var re = /b(c)/;
        out[0] = "abcd".replace(re, "X");
        out[1] = String(re.test("abc"));
        var m = re.exec("abc");
        out[2] = m === null ? "null" : m[0] + m[1];
        out[3] = String("abcabc".match(/c/g));
        out[4] = "a,b,c".split(/,/).join("|");
        out[5] = String("xxbc".search(/bc/));
        out[6] = "aaa".replace(/a/g, function (s) { return s + "!"; });
    }
    return out.join(" ");
}

var plain = run();
check(plain, "aXd true bcc c,c a|b|c 2 a!a!a!", "baseline");

function disturb(what, change, restore, want) {
    // Warm the fast path, change, check, restore, check it resumes.
    run();
    change();
    var got;
    try { got = run(); } catch (e) { got = "threw " + e.name; }
    restore();
    check(got, want, what);
    check(run(), plain, what + " restored");
}

disturb("exec replaced", function () { P.exec = function () { return null; }; },
        function () { P.exec = origExec; },
        "abcd false null null a,b,c -1 aaa");
disturb("exec via defineProperty", function () {
    Object.defineProperty(P, "exec", { value: function () { return null; }, writable: true, configurable: true });
}, function () {
    Object.defineProperty(P, "exec", { value: origExec, writable: true, configurable: true });
}, "abcd false null null a,b,c -1 aaa");
disturb("exec number", function () { P.exec = 5; }, function () { P.exec = origExec; },
        "threw TypeError");
disturb("test replaced", function () { P.test = function () { return "T"; }; },
        function () { P.test = origTest; }, "aXd T bcc c,c a|b|c 2 a!a!a!");
disturb("Symbol.replace replaced", function () { P[Symbol.replace] = function () { return "R"; }; },
        function () { P[Symbol.replace] = origReplace; }, "R true bcc c,c a|b|c 2 R");
disturb("Symbol.match replaced", function () { P[Symbol.match] = function () { return "M"; }; },
        function () { P[Symbol.match] = origMatch; }, "aXd true bcc M a|b|c 2 a!a!a!");
disturb("Symbol.split replaced", function () { P[Symbol.split] = function () { return ["S"]; }; },
        function () { P[Symbol.split] = origSplit; }, "aXd true bcc c,c S 2 a!a!a!");
disturb("Symbol.search replaced", function () { P[Symbol.search] = function () { return 9; }; },
        function () { P[Symbol.search] = origSearch; }, "aXd true bcc c,c a|b|c 9 a!a!a!");
disturb("flags getter", function () {
    Object.defineProperty(P, "flags", { get: function () { return ""; }, configurable: true });
}, function () { Object.defineProperty(P, "flags", flagsDesc); }, "aXd true bcc c a|b|c 2 a!aa");
disturb("global getter", function () {
    Object.defineProperty(P, "global", { get: function () { return false; }, configurable: true });
}, function () { Object.defineProperty(P, "global", globalDesc); }, "aXd true bcc c a|b|c 2 a!aa");
disturb("exec deleted", function () { delete P.exec; }, function () { P.exec = origExec; },
        "threw TypeError");
disturb("prototype of RegExp.prototype", function () {
    Object.setPrototypeOf(P, { exec: function () { return null; } });
}, function () { Object.setPrototypeOf(P, origProto); }, plain);
disturb("Object.prototype exec", function () { Object.prototype.exec = function () { return null; }; },
        function () { delete Object.prototype.exec; }, plain);

// An own property on the instance, and a subclass.
(function () {
    run();
    var re = /b/;
    re.exec = function () { return null; };
    var hits = 0;
    for (var i = 0; i < 200; i++) if (re.test("abc")) hits++;
    check(hits, 0, "own exec");
    class R extends RegExp { exec(s) { return null; } }
    var r = new R("b");
    hits = 0;
    for (var i = 0; i < 200; i++) if (r.test("abc")) hits++;
    check(hits, 0, "subclass exec");
    check("abc".replace(r, "X"), "abc", "subclass replace");
    check(run(), plain, "after instance changes");
})();

// The getter function inside an accessor pair changed in place.
(function () {
    run();
    var g = Object.getOwnPropertyDescriptor(P, "flags").get;
    Object.defineProperty(P, "flags", { get: function () { return ""; } });
    check(run(), "aXd true bcc c a|b|c 2 a!aa", "flags getter in place");
    Object.defineProperty(P, "flags", { get: g });
    check(run(), plain, "flags getter in place restored");
})();

// A store site that cached RegExp.prototype's shape before the guard first ran.
(function () {
    function put(o, v) { o.exec = v; }
    for (var i = 0; i < 50; i++) put(P, origExec);
    run();
    put(P, function () { return null; });
    check(run(), "abcd false null null a,b,c -1 aaa", "cached store site");
    put(P, origExec);
    check(run(), plain, "cached store site restored");
})();

print(failures === 0 ? "ok" : failures + " failures");
