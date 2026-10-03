// P2: PrivateFieldAdd honours [[Extensible]] — a derived class whose base
// constructor returns a non-extensible object cannot install its private
// fields on it, so `super()` throws a TypeError. `this` is already bound to
// the returned object by then, and the object stays non-extensible.
class Base {
    constructor() {
        return Object.preventExtensions({});
    }
}

var returned;
class Derived extends Base {
    #x = 5;
    static hasX(o) { return #x in o; }
    constructor() {
        try {
            super();
        } finally {
            returned = this;
        }
    }
}

var threw = false;
try {
    new Derived();
} catch (e) {
    threw = e instanceof TypeError;
}

if (!threw) throw new Error("expected super() to throw a TypeError");
if (Object.isExtensible(returned)) throw new Error("expected the returned object to stay non-extensible");
if (Derived.hasX(returned)) throw new Error("expected no private field on the returned object");

print("PASS");
