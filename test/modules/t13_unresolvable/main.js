// Test 13: an import of a name the requested module does not export is an
// EARLY SyntaxError, raised at LINK time (ECMA-262 16.2.1.6.2
// InitializeEnvironment step 7 / ResolveExport 16.2.1.6.3) — before the
// importing module's body evaluates. Previously such an import silently bound
// `undefined` and the program ran to completion with exit code 0.
//
// Each fixture is linked through dynamic import() so that the failure is
// observable as a promise rejection inside a module that itself exits 0
// (run.sh keys off the process exit code). The bodies of every bad_*.js below
// contain a top-level `export const r = ...`; because linking fails first,
// none of them ever runs.
//
// Cross-checked against node v24: every case here is
// "SyntaxError: The requested module ... does not provide an export named ..."
// (or "contains conflicting star exports" for the ambiguous one).

var pass = 0, fail = 0;
function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAILED: ' + msg); }
}

var cases = [
    ['./bad_named.js', 'missing named export'],
    ['./bad_default.js', 'missing default export'],
    ['./bad_star_chain.js', 'name absent through an export * chain'],
    ['./bad_ambiguous.js', 'ambiguous star-export collision'],
    ['./bad_alias.js', 'missing export imported under an alias'],
    ['./bad_indirect.js', 'indirect re-export of a missing name']
];

var started = 0, reported = 0;

var jobs = cases.map(function (c) {
    started++;
    return import(c[0]).then(function () {
        reported++;
        assert(false, c[1] + ': expected a link-time rejection, but it resolved');
    }, function (e) {
        reported++;
        assert(e instanceof SyntaxError,
            c[1] + ': expected SyntaxError, got ' + (e && e.name) + ': ' + (e && e.message));
    });
});

// Grade only once every import job has settled. A rejection handled in a
// microtask cannot fail the process by itself: if the jobs never ran, every
// assert above would simply never execute and both counters would read zero,
// so the reported===started check is what makes a vacuous run loud. Chaining
// off Promise.all rather than a fixed number of microtask ticks matters —
// a module-load rejection settles several ticks deep.
Promise.all(jobs).then(function () {
    assert(started > 0 && reported === started,
        'all ' + started + ' import jobs reported (got ' + reported + ')');

    print('t13_unresolvable: ' + pass + ' passed, ' + fail + ' failed');
    if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
});
