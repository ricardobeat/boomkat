// A read site whose receivers share a shape but differ in prototype: every
// fresh object starts at the empty shape, so `this.tag` in a shared function
// body sees one shape and many prototypes.
function check(cond, msg) { if (!cond) throw new Error(msg); }

function make(tag) {
    function C() {}
    C.prototype = { who: function () { return tag; }, tag: tag };
    return C;
}
var classes = [make("a"), make("b"), make("c"), make("d"), make("e")];

function viaThis() { return this.who() + ":" + this.tag; }
function read(o) { return o.tag; }

function build() {
    var objs = [];
    for (var i = 0; i < classes.length; i++) objs.push(Object.create(classes[i].prototype));
    return objs;
}

function sweep(objs, expect) {
    for (var round = 0; round < 50; round++) {
        for (var i = 0; i < objs.length; i++) {
            check(read(objs[i]) === expect[i], "read " + i + " got " + read(objs[i]));
            check(viaThis.call(objs[i]) === "abcde"[i] + ":" + expect[i],
                  "this-read " + i + " got " + viaThis.call(objs[i]));
        }
    }
}

var objs = build();
sweep(objs, ["a", "b", "c", "d", "e"]);

// Mutating a prototype value is seen through every cached entry.
classes[2].prototype.tag = "C2";
check(read(objs[2]) === "C2", "value mutation");
check(read(objs[0]) === "a", "neighbor after value mutation");

// An own property shadows the prototype's.
objs[1].tag = "own";
check(read(objs[1]) === "own", "shadow");
check(read(objs[0]) === "a", "neighbor unaffected after shadow");
delete objs[1].tag;
check(read(objs[1]) === "b", "delete restores prototype value");

// Deleting from the prototype exposes the next link.
var victim = Object.create(classes[3].prototype);
for (var i = 0; i < 20; i++) check(read(victim) === "d", "pre-delete");
delete classes[3].prototype.tag;
for (var i = 0; i < 20; i++) check(read(victim) === undefined, "post-delete");
classes[3].prototype.tag = "d2";
check(read(victim) === "d2", "re-added");

// defineProperty to an accessor.
var calls = 0;
Object.defineProperty(classes[4].prototype, "tag", {
    get: function () { calls++; return "acc"; }, configurable: true
});
for (var i = 0; i < 20; i++) check(read(objs[4]) === "acc", "accessor");
check(calls === 20, "accessor ran each time");
Object.defineProperty(classes[4].prototype, "tag", { value: "e", writable: true, configurable: true });
check(read(objs[4]) === "e", "back to data");

// setPrototypeOf repoints the receiver without touching its shape.
var mover = Object.create(classes[0].prototype);
for (var i = 0; i < 20; i++) check(read(mover) === "a", "mover before");
Object.setPrototypeOf(mover, classes[1].prototype);
for (var i = 0; i < 20; i++) check(read(mover) === "b", "mover after");
Object.setPrototypeOf(mover, null);
check(read(mover) === undefined, "null proto");

// A shadow added on an intermediate link of a longer chain.
var base = { tag: "base" };
var mid = Object.create(base);
var leaf = Object.create(mid);
for (var i = 0; i < 20; i++) check(read(leaf) === "base", "deep chain");
mid.tag = "mid";
check(read(leaf) === "mid", "intermediate shadow");

// A prototype that grows past its inline storage keeps serving reads.
var grower = Object.create(classes[0].prototype);
for (var i = 0; i < 20; i++) check(read(grower) === "a", "grower before");
for (var i = 0; i < 40; i++) classes[0].prototype["extra" + i] = i;
for (var i = 0; i < 20; i++) check(read(grower) === "a", "grower after");
check(grower.extra39 === 39, "grown property");

// Rebuilding the whole population after the churn.
sweep(build(), ["a", "b", "C2", "d2", "e"]);
print("proto_polymorphic_read_ic ok");
