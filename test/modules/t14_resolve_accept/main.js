// Test 14: the ACCEPT side of link-time import resolution. Enforcing
// ResolveExport (see t13_unresolvable) must not over-reject: every form below
// is legal ES and resolves to exactly one binding, so linking has to succeed
// and the bindings have to behave.
//
// Each case is a STATIC import, so an over-rejection here fails the whole
// module at link time and this file's body never runs at all — which run.sh
// reports as a non-zero exit. Cross-checked against node v24.

import { c, bump, named } from './dep.js';
import defaultFn from './dep.js';
import { p, q, r } from './mid.js';
import { renamed } from './aliasmid.js';
import { p as shadowedP } from './shadow.js';
import { leafns } from './nsmid.js';
import { f } from './latedecl.js';
import { depVal, readMain } from './cyc_dep.js';
import { only_a, only_b } from './amb_mid.js';
import * as depNs from './dep.js';

export const mainVal = 'main';

var pass = 0, fail = 0;
function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAILED: ' + msg); }
}

// Live bindings: a mutation in the source module is observed by the importer.
assert(c === 0, 'live binding initial value, got ' + c);
bump();
assert(c === 1, 'live binding observes the source mutation, got ' + c);

// default and named from the same module, together.
assert(defaultFn() === 'D', 'default export');
assert(named === 'N', 'named export alongside default');

// `export * from` plus a local export in the re-exporting module.
assert(p === 1 && q === 2 && r === 3, 'export * re-export, got ' + p + ',' + q + ',' + r);

// Aliased re-export (`export { orig as renamed } from`).
assert(renamed === 'O', 'aliased re-export, got ' + renamed);

// A local export shadows a star-exported name of the same name: that is a
// single resolution, not an ambiguity.
assert(shadowedP === 'local', 'local export shadows star export, got ' + shadowedP);

// `export * as ns from` resolves to the target module's namespace object.
assert(leafns && leafns.z === 7, 'export * as ns from');

// Importing a function that closes over a binding declared LATER in its module.
assert(f() === 'late', 'binding declared later in the target, got ' + f());

// A resolvable cycle: cyc_dep imports back from this module.
assert(depVal === 'dep', 'cyclic import value, got ' + depVal);
assert(readMain() === 'main', 'cyclic back-reference reads this module, got ' + readMain());

// A star-export collision on `dup` makes only THAT name unresolvable; the
// non-colliding names from the same modules must still import fine.
assert(only_a === 10 && only_b === 20,
    'non-colliding names alongside an ambiguous one, got ' + only_a + ',' + only_b);

// A namespace member the module does not export is plain `undefined`, NOT an
// error (§10.4.6.7) — node agrees. Only a named *import* of it is an error.
assert(depNs.missing === undefined, 'absent namespace member is undefined');
assert(depNs.named === 'N', 'present namespace member');

print('t14_resolve_accept: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
