// Prototypal inheritance
// Tests prototype chains, hasOwnProperty, instanceof, Object.create.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Constructor + prototype
function Animal(name) {
    this.name = name;
}
Animal.prototype.speak = function() { return this.name + " speaks"; };

function Dog(name, breed) {
    Animal.call(this, name);
    this.breed = breed;
}
Dog.prototype = Object.create(Animal.prototype);
Dog.prototype.constructor = Dog;
Dog.prototype.fetch = function(item) { return this.name + " fetches " + item; };

var a = new Animal("Generic");
assert(a.speak() === "Generic speaks", "Animal speak");
assert(a.hasOwnProperty("name"), "hasOwnProperty name");
assert(!a.hasOwnProperty("speak"), "speak on prototype");

var d = new Dog("Rex", "Labrador");
assert(d.speak() === "Rex speaks", "inherited speak");
assert(d.fetch("ball") === "Rex fetches ball", "own method");
assert(d instanceof Dog, "instanceof Dog");
assert(d instanceof Animal, "instanceof Animal");
assert(d.hasOwnProperty("breed"), "hasOwnProperty breed");
assert(!d.hasOwnProperty("speak"), "speak not own");
assert(d.constructor === Dog, "constructor is Dog");

// Prototype chain depth
function A() { this.x = 1; }
function B() { A.call(this); this.y = 2; }
function C() { B.call(this); this.z = 3; }
B.prototype = Object.create(A.prototype);
C.prototype = Object.create(B.prototype);

var c = new C();
assert(c.x === 1 && c.y === 2 && c.z === 3, "3-level chain values");
assert(c instanceof C, "instanceof C");
assert(c instanceof A, "instanceof A through chain");

// Object.create with properties descriptor
var base = { greet: function() { return "hi"; } };
var child = Object.create(base);
child.name = "child";
assert(child.greet() === "hi", "inherited method via Object.create");
assert(child.hasOwnProperty("name"), "child own prop");
assert(!child.hasOwnProperty("greet"), "greet inherited");

// Property enumeration: own vs inherited
var keys = [];
for (var k in child) { keys.push(k); }
assert(keys.indexOf("name") >= 0, "for..in sees own");
assert(keys.indexOf("greet") >= 0, "for..in sees inherited");

// Overriding prototype method
Dog.prototype.speak = function() { return this.name + " barks"; };
assert(d.speak() === "Rex barks", "overridden speak affects existing instance");

print("engine/prototypes: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
