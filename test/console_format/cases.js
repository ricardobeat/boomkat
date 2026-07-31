// Format-specifier cases for console.log. Asserted from the shell (run.sh)
// against expected.txt, because what is under test is what console WRITES —
// a script cannot observe its own stdout.
//
// Kept free of anything node cannot run, so `node cases.js` regenerates
// expected.txt verbatim. See run.sh for the regeneration command.

// Substitution is gated on the first argument being a string AND at least one
// further argument existing. With no extra argument the string is verbatim,
// which is why "%%" survives here but collapses two lines further down.
console.log("a %s b");
console.log("a %% b");
console.log("a %d b");
console.log("a %% b", 1);

// A non-string first argument disables substitution entirely.
console.log(1, "%s", "x");
console.log(true, "%s", "x");
console.log(null, "%s", "x");

// Count mismatches in both directions: a starved specifier stays literal, a
// surplus argument is appended space-separated.
console.log("%s %s %s", "A");
console.log("%s", "A", "B", "C");

// Escapes and near-misses.
console.log("a %q b", "X");
console.log("a %", "X");
console.log("a %%s b", "X");
console.log("a %%%s b", "X");
console.log("%s%s%s", 1, 2, 3);
console.log("%d%%", 50, "tail");
console.log("end%s", "");
console.log("%s");

// %c is ignored but still consumes its argument, so "rest" is appended rather
// than being pulled into the directive.
console.log("a %c b", "css", "rest");
console.log("a %c b");

// %s coercions.
console.log("%s", "abc");
console.log("%s", 42);
console.log("%s", 1.5);
console.log("%s", true);
console.log("%s", null);
console.log("%s", undefined);
console.log("%s", Symbol("s"));
console.log("%s", Symbol());
console.log("%s", { toString() { return "CUSTOM"; } });

// %d is Number(), %i is parseInt(), %f is parseFloat() — three different
// coercions, so a boolean is 1 under %d but NaN under %i/%f, and an array is
// NaN under %d but 1 under %i/%f via the string form "1,2".
console.log("%d", 42);
console.log("%d", 1.5);
console.log("%d", true);
console.log("%d", null);
console.log("%d", undefined);
console.log("%d", "abc");
console.log("%d", "0x10");
console.log("%d", Symbol("s"));
console.log("%d", { valueOf() { return 7; } });
console.log("%i", 1.9);
console.log("%i", -1.9);
console.log("%i", "42abc");
console.log("%i", true);
console.log("%i", [1, 2]);
console.log("%f", 1.5);
console.log("%f", "3.9abc");
console.log("%f", true);
console.log("%f", [1, 2]);

// %j is JSON.stringify. undefined, functions and symbols have no JSON form and
// report as undefined at the root; a cycle reports as [Circular] rather than
// throwing the way JSON.stringify itself does.
console.log("%j", "abc");
console.log("%j", 1.5);
console.log("%j", true);
console.log("%j", null);
console.log("%j", { a: 1 });
console.log("%j", [1, 2]);
console.log("%j", { a: { b: { c: { d: { e: 1 } } } } });
console.log("%j", undefined);
console.log("%j", function () {});
console.log("%j", Symbol("s"));

var cyclic = {};
cyclic.self = cyclic;
console.log("%j", cyclic);

var cyclicArr = [];
cyclicArr.push(cyclicArr);
console.log("%j", cyclicArr);

console.log("done");
