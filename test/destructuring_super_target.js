// `super.x` as a destructuring assignment target.
//
// PutValue on a super Reference (§13.15.2 SetSuperProperty) starts the
// property walk at the home object's prototype but uses the current `this` as
// the receiver, so a setter found up the chain runs against the instance and a
// new data property lands on the instance. A plain store against the recorded
// base instead runs the setter with the prototype as `this`, or writes the
// property onto the prototype where every instance sees it.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(a === b, m + ' (got ' + a + ', want ' + b + ')'); }

// A base class whose accessors record the receiver they ran against.
class Base {
    constructor() { this.seen = {}; }
}
['a', 'b', 'c', 'd', 'e'].forEach(function (name) {
    Object.defineProperty(Base.prototype, name, {
        configurable: true,
        set: function (v) { this.seen[name] = v; }
    });
});

class Arr extends Base {
    constructor() {
        super();
        [super.a] = ['A'];
        [, super.b] = ['skip', 'B'];
        [super.c, super.d] = ['C', 'D'];
    }
}
var arr = new Arr();
eq(arr.seen.a, 'A', 'array pattern, super target');
eq(arr.seen.b, 'B', 'array pattern after an elision');
eq(arr.seen.c + arr.seen.d, 'CD', 'two super targets in one pattern');

class Obj extends Base {
    constructor() {
        super();
        ({ p: super.a } = { p: 'A' });
        ({ a: super.b } = { a: 'B' });
        ({ q: super.c = 'default' } = {});
    }
}
var obj = new Obj();
eq(obj.seen.a, 'A', 'object pattern, super target');
eq(obj.seen.b, 'B', 'object pattern, shorthand-named key');
eq(obj.seen.c, 'default', 'object pattern, super target with a default');

// A computed super key.
class Computed extends Base {
    constructor() {
        super();
        var k = 'a';
        [super[k]] = ['A'];
        ({ p: super[('b')] } = { p: 'B' });
    }
}
var comp = new Computed();
eq(comp.seen.a, 'A', 'computed super key, array pattern');
eq(comp.seen.b, 'B', 'computed super key, object pattern');

// A rest element into a super target.
class Rest extends Base {
    constructor() {
        super();
        [, ...super.a] = ['skip', 1, 2];
    }
}
eq(new Rest().seen.a.join(','), '1,2', 'rest into a super target');

// With no setter on the chain the property is created on the instance, not on
// the prototype, because the receiver is `this`.
class Plain {}
class Writes extends Plain {
    constructor() {
        super();
        [super.fresh] = ['v'];
    }
}
var w = new Writes();
eq(w.fresh, 'v', 'a new property lands on the instance');
ok(Object.prototype.hasOwnProperty.call(w, 'fresh'),
   'the new property is an own property of the instance');
ok(!Object.prototype.hasOwnProperty.call(Plain.prototype, 'fresh'),
   'the prototype is untouched');
ok(!Object.prototype.hasOwnProperty.call(Writes.prototype, 'fresh'),
   'the derived prototype is untouched either');

// Two instances do not share the value.
var w2 = new Writes();
w2.fresh = 'other';
eq(w.fresh, 'v', 'instances keep separate values');

// A method body, not just a constructor.
class Method extends Base {
    run() { [super.a] = ['M']; return this.seen.a; }
    runObj() { ({ p: super.b } = { p: 'N' }); return this.seen.b; }
}
eq(new Method().run(), 'M', 'super target in a method');
eq(new Method().runObj(), 'N', 'super target in a method, object pattern');

// An object literal method has a home object too.
var homeSeen = {};
var proto = {};
Object.defineProperty(proto, 'a', { set: function (v) { homeSeen.a = v; } });
var lit = { __proto__: proto, run() { [super.a] = ['L']; } };
lit.run();
eq(homeSeen.a, 'L', 'super target in an object literal method');

// An ordinary member target still stores against its own base.
var plainTarget = {};
[plainTarget.x] = ['x'];
({ p: plainTarget.y } = { p: 'y' });
eq(plainTarget.x + plainTarget.y, 'xy', 'a non-super member target is unaffected');

// A setter on a plain member target receives that object as the receiver.
var recv = null;
var holder = {};
Object.defineProperty(holder, 'z', { set: function (v) { recv = this; } });
[holder.z] = [1];
ok(recv === holder, 'a plain member target uses its own base as receiver');

if (fail === 0) {
    print('PASS: super destructuring target (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
