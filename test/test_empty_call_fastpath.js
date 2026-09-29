function assert(value, message) { if (!value) throw new Error(message); }

function emptyCallTarget() {}
function invokeEmptyTarget(argument) { return emptyCallTarget(argument); }
var sideEffects = 0;
function makeCallArgument() { sideEffects++; return {payload: 'kept alive'}; }

assert(invokeEmptyTarget(makeCallArgument()) === undefined, 'empty function result');
assert(sideEffects === 1, 'argument evaluation');

// A cached empty-function decision must follow the current binding value.
emptyCallTarget = function () { return 42; };
assert(invokeEmptyTarget(makeCallArgument()) === 42, 'reassigned global callee');
assert(sideEffects === 2, 'reassigned callee argument evaluation');

var defaultEffects = 0;
function emptyWithDefault(value = (defaultEffects++, 7)) {}
emptyWithDefault();
assert(defaultEffects === 1, 'default parameter initialization');

function ownedEmptyTarget() {}
function invokeOwnedTarget() { return ownedEmptyTarget(); }
assert(invokeOwnedTarget() === undefined, 'owned callee result');

function identityTarget(value) { return value; }
assert(identityTarget() === undefined, 'identity missing argument');
assert(identityTarget(identityTarget) === identityTarget, 'borrowed callee returned as argument');
var identityObject = {nested: {value: 73}};
assert(identityTarget(identityObject) === identityObject, 'heap argument returned');
var identitySymbol = Symbol('identity');
assert(identityTarget(identitySymbol) === identitySymbol, 'symbol argument returned');
var identityBigInt = 12345678901234567890n;
assert(identityTarget(identityBigInt) === identityBigInt, 'BigInt argument returned');
var identityFreshString = 'fresh-' + sideEffects;
assert(identityTarget(identityFreshString) === identityFreshString, 'string argument returned');
var identityArgumentEffects = 0;
function identityExtraArgument() { identityArgumentEffects++; return 88; }
assert(identityTarget(19, identityExtraArgument()) === 19, 'extra argument ignored');
assert(identityArgumentEffects === 1, 'extra argument evaluation');

function invokeOwnedIdentity(value) {
    var ownedIdentity = function (argument) { return argument; };
    return ownedIdentity(value);
}
assert(invokeOwnedIdentity(identityObject) === identityObject, 'owned identity callee');
var identityHolder = {call: identityTarget};
assert(identityHolder.call(identityObject) === identityObject, 'identity method receiver');
function tailIdentityWrapper(value) { return identityTarget(value); }
assert(tailIdentityWrapper(identityObject) === identityObject, 'identity tail call');

function addFastintTarget(left, right) { return left + right; }
assert(addFastintTarget(3, 7) === 10, 'fastint addition body');
assert(addFastintTarget(140737488355327, 1) === 140737488355328, 'fastint overflow to Number');
assert(addFastintTarget(-140737488355328, -1) === -140737488355329, 'negative fastint overflow to Number');
assert(addFastintTarget(1.25, 2.5) === 3.75, 'Number addition fallback');
assert(addFastintTarget('left', 7) === 'left7', 'string addition fallback');
assert(addFastintTarget(2n, 3n) === 5n, 'BigInt addition fallback');
var coercions = 0;
var addCoercible = {valueOf: function () { coercions++; return 4; }};
assert(addFastintTarget(addCoercible, 3) === 7 && coercions === 1, 'object addition fallback');
var missingSum = addFastintTarget(3);
assert(missingSum !== missingSum, 'missing argument follows normal addition');

var receiver = {call: function () {}};
assert(receiver.call({payload: 'method argument'}) === undefined, 'method receiver');

function tailEmptyTarget() {}
function tailEmptyWrapper() { return tailEmptyTarget(); }
assert(tailEmptyWrapper() === undefined, 'tail call result');

async function asyncEmptyTarget() {}
assert(asyncEmptyTarget() instanceof Promise, 'async empty function result');

function* generatorEmptyTarget() {}
assert(generatorEmptyTarget().next().done, 'generator empty function result');

class EmptyCallClass { constructor() {} }
var classCallThrew = false;
try { EmptyCallClass(); } catch (error) { classCallThrew = error instanceof TypeError; }
assert(classCallThrew, 'class constructor call error');
