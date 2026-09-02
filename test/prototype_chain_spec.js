// Every builtin prototype's [[Prototype]] link.
//
// These are set where each prototype is created, which is only safe because
// register_object_constructor runs before every other registrar, so
// Object.prototype already exists. The one exception is %GeneratorPrototype%,
// whose parent is %Iterator.prototype% (ES2025 §27.8.1) -- generators are
// registered before Iterator, so that link is still made afterwards in
// register_builtins.

function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        throw new Error(msg + ": got " + String(actual) + ", expected " + String(expected));
    }
}

const OP = Object.prototype;

// Object.prototype is the root of the chain.
assertEq(Object.getPrototypeOf(OP), null, "Object.prototype [[Prototype]] is null");

// Every other builtin prototype inherits from it directly.
const direct = [
    ["Number", Number], ["Boolean", Boolean], ["String", String],
    ["Error", Error], ["Array", Array], ["Function", Function],
    ["Date", Date], ["RegExp", RegExp], ["Map", Map], ["Set", Set],
    ["WeakMap", WeakMap], ["WeakSet", WeakSet], ["Symbol", Symbol],
    ["Promise", Promise],
];
for (const [name, ctor] of direct) {
    assertEq(Object.getPrototypeOf(ctor.prototype), OP, name + ".prototype inherits Object.prototype");
}

// Error subclasses chain through Error.prototype, not straight to Object.
for (const sub of [TypeError, RangeError, ReferenceError, SyntaxError, EvalError, URIError]) {
    assertEq(Object.getPrototypeOf(sub.prototype), Error.prototype, sub.name + ".prototype inherits Error.prototype");
}

// Generator chain: g() -> g.prototype -> %GeneratorPrototype% -> %IteratorPrototype% -> Object.prototype
function* gen() { yield 1; yield 2; yield 3; }
const genProto = Object.getPrototypeOf(Object.getPrototypeOf(gen()));
assertEq(typeof genProto.next, "function", "%GeneratorPrototype% has next");
const iterProto = Object.getPrototypeOf(genProto);
assertEq(typeof iterProto.map, "function", "%IteratorPrototype% has the iterator helpers");
assertEq(Object.getPrototypeOf(iterProto), OP, "%IteratorPrototype% inherits Object.prototype");

// The helpers must actually reach a generator through that chain -- this is
// what the %GeneratorPrototype% -> %IteratorPrototype% link buys.
assertEq([...gen().map(x => x * 2)].join(","), "2,4,6", "generator .map");
assertEq([...gen().filter(x => x > 1)].join(","), "2,3", "generator .filter");
assertEq([...gen().take(2)].join(","), "1,2", "generator .take");

// Constructors themselves inherit from Function.prototype.
for (const [name, ctor] of direct) {
    assertEq(Function.prototype.isPrototypeOf(ctor), true, name + " inherits Function.prototype");
}

// Inherited Object.prototype members are reachable from instances.
assertEq(typeof new Map().hasOwnProperty, "function", "hasOwnProperty via Map chain");
assertEq(typeof new Date().propertyIsEnumerable, "function", "propertyIsEnumerable via Date chain");
assertEq((5).toString(), "5", "Number.prototype.toString");
assertEq(OP.isPrototypeOf(new Date()), true, "Date instance inherits Object.prototype");
assertEq(new Map() instanceof Map, true, "instanceof through the chain");

// @@toStringTag still resolves for the types that carry one.
assertEq(Object.prototype.toString.call(new Set()), "[object Set]", "Set toStringTag");
assertEq(Object.prototype.toString.call(new Map()), "[object Map]", "Map toStringTag");
assertEq(Object.prototype.toString.call(Math), "[object Math]", "Math toStringTag");

print("OK");
