// Inlined bodies whose field reads land beyond the caller's frame (the second call of
// `this.output().value = this.input().value`): the reads become OBJECT nodes, compared by equality
// branches in their registers, or numbers when an arithmetic use asks. After warmup the fields
// change kind: strings, doubles, null, undefined, booleans, objects with valueOf.
var out = [];
var FWD = 1, BWD = -1;
function B(a, b) { this.v1 = a; this.v2 = b; this.direction = FWD; this.k = 0; }
B.prototype.input = function () { return (this.direction == FWD) ? this.v1 : this.v2; };
B.prototype.output = function () { return (this.direction === FWD) ? this.v2 : this.v1; };
B.prototype.isNull = function () { return this.v1 == null ? 1 : 2; };
B.prototype.bump = function () { return this.k + 1; };
B.prototype.execute = function () { this.output().value = this.input().value; };
B.prototype.count = function () { return this.isNull() + this.bump() + this.isNull(); };

var b = new B({ value: 1 }, { value: 2 });
var s = 0;
for (var i = 0; i < 20000; i++) {
    b.v1.value = i;
    b.execute();
    s += b.count();
    if (i % 1000 == 999) b.direction = -b.direction;
}
out.push("warm " + b.v1.value + " " + b.v2.value + " " + s);

function run(label) {
    var r = [];
    try {
        b.execute();
        r.push(b.count());
    } catch (e) { r.push("threw " + e.constructor.name); }
    out.push(label + " " + r.join(",") + " " + b.v1.value + " " + b.v2.value);
}
b.direction = "1"; run("strdir");          // "1" == 1 but not === 1
b.direction = 1.0; run("dbldir");
b.direction = 1.5; run("fracdir");
b.direction = { valueOf: function () { return 1; } }; run("objdir");
b.direction = true; run("booldir");
b.direction = FWD;
b.k = 2.5; run("dblk");
b.k = "7"; run("strk");
b.k = null; run("nullk");
b.k = 0;
var saved = b.v1;
b.v1 = null; try { run("nullv1"); } catch (e) { out.push("nullv1 threw"); }
b.v1 = undefined; out.push("undef " + b.isNull());
b.v1 = 0; out.push("zero " + b.isNull());
b.v1 = saved;
for (var i = 0; i < 5000; i++) { b.execute(); s += b.count(); }
out.push("again " + s + " " + b.v2.value);
print(out.join("\n"));
