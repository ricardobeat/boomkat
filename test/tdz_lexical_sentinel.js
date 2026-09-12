// A let/const/class binding must throw ReferenceError when read or written
// inside its temporal dead zone, even when an enclosing scope has a binding
// of the same name.
//
// The compiler resolves a TDZ read through the environment rather than the
// binding's register (resolve_var refuses the register while the scope entry
// is is_tdz), so the lookup can hit the INITTZ sentinel. Two paths dropped
// that sentinel and let the lookup walk out to the OUTER binding instead:
//
//  1. The env-write elision pass NOP'd INITTZ for any function with no
//     closures, keeping it only for names used by `typeof`. A plain GETVAR
//     or PUTVAR_ASSIGN read in the dead zone then found the outer binding.
//  2. An arrow's ConciseBody never goes through block(), so it never ran
//     block()'s let/const TDZ pre-scan at all.
//
// Both only misbehaved when an outer binding of the same name existed: with
// no outer binding the lookup failed anyway and threw the right error type
// for the wrong reason. Hence the `var shadowed` at the bottom.

var pass = 0;
var fail = 0;
function check(tag, fn) {
    try {
        fn();
        print("FAIL: " + tag + " (no throw)");
        fail = fail + 1;
    } catch (e) {
        if (e instanceof ReferenceError) {
            pass = pass + 1;
        } else {
            print("FAIL: " + tag + " (" + e.name + ")");
            fail = fail + 1;
        }
    }
}

// --- reads, non-captured (the elision-pass path) ---
check("fn: let read",            function () { let shadowed = shadowed; });
check("fn: let read in expr",    function () { let shadowed = shadowed + 1; });
check("fn: const read",          function () { const shadowed = shadowed; });
check("fn: typeof in TDZ",       function () { typeof shadowed; let shadowed; });

// --- writes reach the binding with no GETVAR at all ---
check("fn: destructuring target", function () { let shadowed = [shadowed] = []; });
check("fn: destructuring hole",   function () { let shadowed = [shadowed] = [,]; });
check("fn: object destructuring", function () { let shadowed = ({shadowed} = {}); });
check("fn: plain assignment",     function () { shadowed = 1; let shadowed; });
check("fn: compound assignment",  function () { shadowed += 1; let shadowed; });
check("fn: increment",            function () { shadowed++; let shadowed; });
check("fn: logical assignment",   function () { let shadowed = (shadowed &&= 0); });

// --- the same cases inside an arrow (the ConciseBody path) ---
check("arrow: let read",            () => { let shadowed = shadowed; });
check("arrow: const read",          () => { const shadowed = shadowed; });
check("arrow: destructuring target",() => { let shadowed = [shadowed] = []; });
check("arrow: destructuring hole",  () => { let shadowed = [shadowed] = [,]; });
check("arrow: plain assignment",    () => { shadowed = 1; let shadowed; });
check("arrow: increment",           () => { shadowed++; let shadowed; });
check("arrow: logical assignment",  () => { let shadowed = (shadowed &&= 0); });
check("arrow: class binding",       () => { class shadowed extends (shadowed &&= 0) {} });

// --- captured bindings kept working throughout; guard that too ---
check("fn: captured let read",   function () { let shadowed = shadowed; function g() { return shadowed; } });
check("arrow: captured let read",() => { let shadowed = shadowed; function g() { return shadowed; } });

// --- nested block inside each body shape ---
check("fn: nested block",    function () { { let shadowed = shadowed; } });
check("arrow: nested block", () => { { let shadowed = shadowed; } });

// Once initialized, the binding reads normally and shadows the outer one.
(function () {
    let shadowed = 1;
    if (shadowed !== 1) { print("FAIL: initialized let does not read back"); fail = fail + 1; }
    else { pass = pass + 1; }
})();

// The outer `var` is hoisted but not yet assigned at this point in the
// script, so an unshadowed read sees `undefined` rather than throwing —
// the var binding exists, which is exactly what made the TDZ bug visible.
(function () {
    if (shadowed !== undefined) { print("FAIL: hoisted outer var should read undefined"); fail = fail + 1; }
    else { pass = pass + 1; }
})();

// The outer binding these all shadow. Declared last on purpose: it is hoisted,
// so it exists for every check above, which is what made the bug observable.
var shadowed = 99;

print("tdz_lexical_sentinel: " + pass + " passed, " + fail + " failed");
if (fail > 0) { throw new Error("tdz_lexical_sentinel failed"); }
