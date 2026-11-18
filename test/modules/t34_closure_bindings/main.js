// Module bindings read from closures, class methods and arrows warmed past the JIT threshold: a live
// imported binding that changes after the reads compiled, module let/const/var (one read in its
// TDZ), and bindings of a cycle of imports.
import { counter, fixed, bump } from "./lib.js";
import { setA, readBFromA } from "./cyc_a.js";
import { setB } from "./cyc_b.js";

const fail = (what, got, want) => { throw new Error(what + ": got " + got + ", want " + want); };
const check = (what, got, want) => { if (got !== want) fail(what, got, want); };

class Reader {
    static count() { return counter; }
    static both() { return fixed + modConst + modLet + modVar; }
}
const early = () => LATE;
try { early(); fail("TDZ", "no error", "ReferenceError"); } catch (e) { check("TDZ", e.constructor.name, "ReferenceError"); }

const modConst = "c";
let modLet = "l";
var modVar = "v";
const LATE = "late";

for (let i = 0; i < 3000; i++) { Reader.count(); Reader.both(); early(); }
check("live import", Reader.count(), 0);
bump();
check("live import after change", Reader.count(), 1);
for (let i = 0; i < 3000; i++) bump();
check("live import after more", Reader.count(), 3001);
check("module bindings", Reader.both(), "fixedclv");
modLet = "L";
modVar = "V";
check("module bindings after writes", Reader.both(), "fixedcLV");
check("late const", early(), "late");

for (let i = 0; i < 3000; i++) readBFromA();
check("cycle", readBFromA(), "a0/b0");
setA("a1");
setB("b1");
check("cycle after writes", readBFromA(), "a1/b1");
