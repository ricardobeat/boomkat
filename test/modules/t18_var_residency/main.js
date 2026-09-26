// Register residency for module-level `var` (the module analogue of the
// script-mode slot globals): exported, captured, and eval-visible names stay
// in the module environment; everything else may live in a register.
import { listed, plain, renamed, second, getCounter, setAll, callMain,
         topDecl, topListed, topRenamed } from './dep.js';
import { seen } from './evalmod.js';
import * as self from './main.js';

function assert(c, m) { if (!c) { throw new Error('FAIL: ' + m); } }

export var shared = 0;
export function bump() { return ++shared; }

// Top-level only: register-resident.
var local = 0;
for (var i = 0; i < 100; i++) local += i;
assert(local === 4950, 'register-resident var accumulates');

// Referenced from dep.js's closure, and exported live bindings.
assert(topDecl === 2, 'export var written only at top level');
assert(topListed === 4, 'export list var written only at top level');
assert(topRenamed === 2, 'aliased export written only at top level');

assert(getCounter() === 45, 'captured var in a dependency');
assert(listed === 1 && plain === 3 && renamed === 2 && second === 5, 'initial exports');
setAll();
assert(listed === 10, 'export var is live');
assert(plain === 30, 'export list is live');
assert(renamed === 20, 'aliased export is live');
assert(second === 50, 'second declarator of an export var is live');

// An exported var written from this body must reach importers, here the
// module's own namespace.
callMain();
callMain();
assert(shared === 2 && self.shared === 2, 'exported var written through a cycle');
shared = 7;
assert(self.shared === 7, 'exported var written from the body');

// Read by closures created later: must stay in the environment.
var late = 1;
late = 7;
const readLate = () => late;
assert(readLate() === 7, 'arrow sees the var');
class K { get v() { return late; } }
late = 8;
assert(new K().v === 8, 'class method sees the var');

// Register values survive a top-level await suspension.
var acc = 0;
for (var j = 0; j < 5; j++) { acc += await Promise.resolve(j); }
assert(acc === 10, 'register-resident var across top-level await');

assert(seen === 2, 'direct eval sees the current value');
