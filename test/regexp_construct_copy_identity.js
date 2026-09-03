// `new RegExp(re)` must always allocate a FRESH object.
//
// ES2024 22.2.4.1 step 1 takes the "return the pattern unchanged" shortcut
// only `If NewTarget is undefined` — that is, only for `RegExp(re)` called as
// a function. The engine took it for `new` too, so `new RegExp(re) === re`.
//
// That aliasing is observable well beyond identity: freezing the copy's
// lastIndex froze the ORIGINAL's, after which an unrelated `re.lastIndex = n`
// threw "TypeError: Cannot assign to read only property".

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

var re = /ab+c/gim;

// --- identity: only the flagless function call aliases ---
check("RegExp(re) aliases",           RegExp(re) === re,          true);
check("new RegExp(re) is fresh",      new RegExp(re) === re,      false);
check("RegExp(re, 'y') is fresh",     RegExp(re, "y") === re,     false);
check("new RegExp(re, 'y') is fresh", new RegExp(re, "y") === re, false);

// --- a copy still carries source and flags ---
check("copy keeps source", new RegExp(re).source, "ab+c");
check("copy keeps flags",  new RegExp(re).flags,  "gim");
check("explicit flags win", new RegExp(re, "y").flags, "y");
check("copy lastIndex starts 0", new RegExp(re).lastIndex, 0);

// --- the copy is independent of the original ---
var orig = /a/g;
var copy = new RegExp(orig);
copy.lastIndex = 42;
check("assigning copy.lastIndex leaves original", orig.lastIndex, 0);

Object.defineProperty(copy, "lastIndex", { value: 1, writable: false });
check("freezing the copy leaves the original writable",
      Object.getOwnPropertyDescriptor(orig, "lastIndex").writable, true);
var threw = false;
try { orig.lastIndex = 7; } catch (e) { threw = true; }
check("original still assignable", threw, false);
check("original took the new value", orig.lastIndex, 7);

// The reverse direction too: freezing the original must not freeze a later copy.
var orig2 = /a/g;
Object.defineProperty(orig2, "lastIndex", { value: 0, writable: false });
var copy2 = new RegExp(orig2);
check("copy of a frozen regexp is writable",
      Object.getOwnPropertyDescriptor(copy2, "lastIndex").writable, true);

// --- subclassing: new.target still drives the prototype ---
class MyRe extends RegExp {}
var sub = new MyRe(re);
check("subclass prototype", Object.getPrototypeOf(sub) === MyRe.prototype, true);
check("subclass is fresh", sub === re, false);
check("subclass keeps flags", sub.flags, "gim");

// --- a regexp-like object (@@match) is read for source/flags, not aliased ---
var fake = { [Symbol.match]: true, source: "xy", flags: "i" };
check("regexp-like source", new RegExp(fake).source, "xy");
check("regexp-like flags",  new RegExp(fake).flags,  "i");

// --- a copy matches independently of the original's lastIndex ---
var g1 = /a/g;
g1.lastIndex = 99;
var g2 = new RegExp(g1);
check("fresh copy matches from 0", g2.exec("bab")[0], "a");

if (failures === 0) { print("regexp_construct_copy_identity: all checks passed"); }
