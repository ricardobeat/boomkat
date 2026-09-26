// Every exported `var` below must stay in the module environment, where
// main.js reads it through a live binding. The rest may live in registers.
import { bump } from './main.js';

export var listed = 1;
var aliased = 2;
var plain = 3;
export { plain, aliased as renamed };
export var first = 0, second = 5;

var counter = 0;
for (var k = 0; k < 10; k++) counter += k;

export function getCounter() { return counter; }
export function setAll() { listed = 10; plain = 30; aliased = 20; second = 50; }
export function callMain() { return bump(); }

// Exported but referenced only at top level: nothing but the export keeps
// these in the environment.
export var topDecl = 1;
topDecl = 2;
var topListed = 3;
topListed = 4;
var topAliased;
for (var n = 0; n < 3; n++) topAliased = n;
export { topListed, topAliased as topRenamed };
