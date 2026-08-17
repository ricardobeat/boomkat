// Link-time enforcement of ResolveExport (ECMA-262 16.2.1.6.3 / 16.2.1.6.2
// InitializeEnvironment step 7). An import of a name the requested module does
// not export is an EARLY SyntaxError raised while linking, before any module
// body evaluates. Before this was enforced the import silently bound
// `undefined` and the whole program ran to completion with exit code 0.
//
// Static `import` cannot express a rejection inside a single script file, so
// the reject side is driven through dynamic import(), which links the target
// through the same validate_imports path and surfaces the failure as a promise
// rejection. The static-import counterpart lives in test/modules/ (t13/t14),
// where run.sh can assert on the process exit code.
//
// The accept side matters as much as the reject side: over-rejecting here
// would break live bindings, star re-exports and resolvable cycles.

var pass = 0, fail = 0;
function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAILED: ' + msg); }
}

// The fixtures are shared with test/modules/t13_unresolvable (reject) and
// test/modules/t14_resolve_accept (accept) rather than duplicated here.
//
// A dynamic import() issued from a plain script resolves its specifier
// against the referencing script's own directory (the filename now rides the
// compiled function), so these paths are relative to test/, this file's
// directory, not to the process working directory.
var bad = './modules/t13_unresolvable/';
var ok = './modules/t14_resolve_accept/';

var started = 0, reported = 0;
var jobs = [];

function expectReject(spec, label) {
    started++;
    jobs.push(import(bad + spec).then(function () {
        reported++;
        assert(false, label + ': expected a rejection, but the import resolved');
    }, function (e) {
        reported++;
        assert(e instanceof SyntaxError,
            label + ': expected SyntaxError, got ' + (e && e.name));
    }));
}

function expectResolve(spec, label, check) {
    started++;
    jobs.push(import(ok + spec).then(function (ns) {
        reported++;
        assert(check(ns), label + ': namespace did not match expectation');
    }, function (e) {
        reported++;
        assert(false, label + ': expected resolution, got ' + (e && e.name) + ': ' + (e && e.message));
    }));
}

// --- reject side -----------------------------------------------------------
expectReject('bad_named.js', 'missing named export');
expectReject('bad_default.js', 'missing default export');
expectReject('bad_star_chain.js', 'name missing through export *');
expectReject('bad_ambiguous.js', 'ambiguous star-export collision');
expectReject('bad_alias.js', 'missing export imported under an alias');
expectReject('bad_indirect.js', 'indirect re-export of a missing name');

// --- accept side -----------------------------------------------------------
// Linking these must succeed; each namespace exposes the bindings its own
// module resolved, so a successful import is itself the assertion.
expectResolve('mid.js', 'export * re-export', function (ns) {
    return ns.p === 1 && ns.q === 2 && ns.r === 3;
});
expectResolve('aliasmid.js', 'aliased re-export', function (ns) { return ns.renamed === 'O'; });
expectResolve('shadow.js', 'local export shadows star', function (ns) { return ns.p === 'local'; });
expectResolve('nsmid.js', 'export * as ns from', function (ns) { return ns.leafns.z === 7; });
expectResolve('latedecl.js', 'binding declared later in the target',
    function (ns) { return ns.f() === 'late'; });
expectResolve('amb_mid.js', 'non-colliding names alongside an ambiguous one',
    function (ns) { return ns.only_a === 10 && ns.only_b === 20; });
expectResolve('dep.js', 'absent namespace member is undefined, not an error',
    function (ns) { return ns.missing === undefined && ns.named === 'N'; });

// Grade only once every import job has settled. A rejection handled inside a
// microtask cannot fail the process on its own — if the jobs never ran, every
// assert above would simply never execute and the counters would both read
// zero, so the reported===started check is what makes a vacuous run loud.
// Chaining off Promise.all rather than a fixed number of microtask ticks
// matters: a module-load rejection settles several ticks deep.
Promise.all(jobs).then(function () {
    assert(started > 0 && reported === started,
        'all ' + started + ' import jobs reported (got ' + reported + ')');

    print('module_unresolvable_import: ' + pass + ' passed, ' + fail + ' failed');
    if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
});
