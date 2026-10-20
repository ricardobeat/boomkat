// RegExp operations benchmark
// Tests exec, match, replace, split with various patterns

var bench = function(name, fn, iterations) {
    var start = Date.now();
    for (var i = 0; i < iterations; i++) { fn(); }
    var elapsed = Date.now() - start;
    print(name + ": " + elapsed + " ms (" + iterations + " iterations)");
};

var N = 2000;

// ── Test strings ────────────────────────────────────────────────────────────
var shortStr = "Hello, World!";
var longStr  = "The quick brown fox jumps over the lazy dog. The fox is quick and brown. End.";
var emailStr = "user@example.com, admin@test.org, support@company.co.uk";
var numStr   = "123-456-7890";
var htmlStr  = "<div class='foo'><p>Hello</p><a href='#'>link</a></div>";

// ── Simple literal pattern: exec ────────────────────────────────────────────
var reLiteral = /fox/;
bench("exec (literal)", function () {
    var m = reLiteral.exec(longStr);
}, N);

// ── Simple literal pattern: match ──────────────────────────────────────────
bench("match (literal)", function () {
    var m = longStr.match(/fox/);
}, N);

// ── Simple literal pattern: test ───────────────────────────────────────────
bench("test (literal)", function () {
    var t = reLiteral.test(longStr);
}, N);

// ── Pattern with capturing groups: exec ────────────────────────────────────
var reGroups = /(\w+)@(\w+\.\w+)/;
bench("exec (groups)", function () {
    var m = reGroups.exec(emailStr);
}, N);

// ── Pattern with capturing groups: match ───────────────────────────────────
bench("match (groups)", function () {
    var m = emailStr.match(/(\w+)@(\w+\.\w+)/);
}, N);

// ── Global flag: exec in loop ──────────────────────────────────────────────
var reGlobal = /\w+/g;
bench("exec global (loop)", function () {
    reGlobal.lastIndex = 0;
    var m;
    while ((m = reGlobal.exec(longStr)) !== null) {}
}, N);

// ── Global flag: match ─────────────────────────────────────────────────────
bench("match (global)", function () {
    var m = longStr.match(/\w+/g);
}, N);

// ── replace (simple string replacement) ────────────────────────────────────
bench("replace (string)", function () {
    var s = longStr.replace("fox", "cat");
}, N);

// ── replace (regexp, plain string replacement) ─────────────────────────────
bench("replace (re, string)", function () {
    var s = longStr.replace(/fox/, "cat");
}, N);

// ── replace (regexp, global) ───────────────────────────────────────────────
bench("replace (re global, string)", function () {
    var s = longStr.replace(/the /gi, "a ");
}, N);

// ── replace (regexp, function replacer) ────────────────────────────────────
bench("replace (re, function)", function () {
    var s = longStr.replace(/\w+/g, function (match) {
        return match.toUpperCase();
    });
}, N);

// ── replace with $1 backreference ──────────────────────────────────────────
bench("replace ($1 backref)", function () {
    var s = emailStr.replace(/(\w+)@(\w+\.\w+)/g, "$1 at $2");
}, N);

// ── split (simple string delimiter) ────────────────────────────────────────
bench("split (string)", function () {
    var a = longStr.split(" ");
}, N);

// ── split (regexp delimiter) ───────────────────────────────────────────────
bench("split (re)", function () {
    var a = longStr.split(/\s+/);
}, N);

// ── split (regexp with groups) ─────────────────────────────────────────────
bench("split (re with groups)", function () {
    var a = numStr.split(/(-)/);
}, N);

// ── search ─────────────────────────────────────────────────────────────────
bench("search", function () {
    var idx = longStr.search(/jumps/);
}, N);

// ── Compile regexp and test ────────────────────────────────────────────────
bench("compile+test", function () {
    var re = new RegExp("[a-z]+", "i");
    var t = re.test(shortStr);
}, N);

// ── Email validation regexp ─────────────────────────────────────────────────
var reEmail = /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/;
bench("email test (valid)", function () {
    var t = reEmail.test("user@example.com");
}, N);
bench("email test (invalid)", function () {
    var t = reEmail.test("not-an-email");
}, N);

// ── Mixed: extract then replace ────────────────────────────────────────────
bench("exec+replace mix", function () {
    var m = /(\w+)@(\w+\.\w+)/.exec(emailStr);
    var s = emailStr.replace(m ? m[1] : "", "REDACTED");
}, N);

print("done");
