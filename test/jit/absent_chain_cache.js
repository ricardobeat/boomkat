// Absent-property stores from one constructor site whose receivers share a
// shape but not a prototype, and prototype changes after the site cached
// that its chain lacks the key.
var log = [];
function Base(v) {
    this.v = v;
    this.w = v + 1;
}
var protos = [];
var kinds = [];
for (var k = 0; k < 12; k++) {
    (function (k) {
        function K() { Base.call(this, k); }
        K.prototype = Object.create(Base.prototype);
        K.prototype.tag = "K" + k;
        protos.push(K.prototype);
        kinds.push(K);
    })(k);
}
function build() {
    var out = [];
    for (var r = 0; r < 60; r++) {
        for (var i = 0; i < kinds.length; i++) out.push(new kinds[i]());
    }
    return out;
}
function summary(objs) {
    var s = 0;
    for (var i = 0; i < objs.length; i++) s += objs[i].v * 3 + objs[i].w;
    return s;
}
var a = build();
log.push("plain " + summary(a) + " own " + Object.keys(a[5]).join());

// A setter appears on one prototype after the cache filled: its receivers run it.
var seen = 0;
Object.defineProperty(protos[3], "v", { set: function (x) { seen += x; }, get: function () { return -1; }, configurable: true });
var b = build();
log.push("setter seen " + seen + " own3 " + Object.keys(b[3]).join() + " v3 " + b[3].v + " v4 " + b[4].v);

// A read-only data property inherited from a prototype blocks the store.
Object.defineProperty(protos[7], "w", { value: 100, writable: false, configurable: true });
var c = build();
log.push("readonly w7 " + c[7].w + " own7 " + Object.keys(c[7]).join() + " w8 " + c[8].w);

// Removing the blocking properties restores plain own stores.
delete protos[3].v;
delete protos[7].w;
var d = build();
log.push("restored " + Object.keys(d[3]).join() + " " + d[3].v + " " + d[7].w + " " + summary(d));

// Repointing a prototype's own prototype to one with a setter.
var hits = 0;
var guard = {};
Object.defineProperty(guard, "w", { set: function (x) { hits++; }, configurable: true });
Object.setPrototypeOf(protos[5], guard);
var e = build();
log.push("setPrototypeOf hits " + hits + " own5 " + Object.keys(e[5]).join() + " w5 " + e[5].w);
Object.setPrototypeOf(protos[5], Base.prototype);

// A key added to the shared base prototype after caching.
var baseSets = 0;
Object.defineProperty(Base.prototype, "v", { set: function (x) { baseSets++; }, configurable: true });
var f = build();
log.push("base proto setter " + baseSets + " own0 " + Object.keys(f[0]).join());
delete Base.prototype.v;
var g = build();
log.push("base restored " + Object.keys(g[0]).join() + " " + summary(g));

// Object.prototype gains a setter, then loses it.
var top = 0;
Object.defineProperty(Object.prototype, "w", { set: function (x) { top++; }, configurable: true });
var h = build();
log.push("Object.prototype setter " + top + " own " + Object.keys(h[0]).join());
delete Object.prototype.w;
var i2 = build();
log.push("Object.prototype restored " + Object.keys(i2[0]).join() + " " + summary(i2));

// A frozen prototype blocks the inherited-writable-less add the same way.
Object.freeze(protos[9]);
var j = build();
log.push("frozen proto own9 " + Object.keys(j[9]).join() + " v9 " + j[9].v);

print(log.join("\n"));
