// A dead pooled object is reclaimed without a visit unless it owns something
// its teardown releases. Each kind of ownership is taken after allocation
// here, by objects that die across many collections while survivors in the
// same pages keep their values; a missed release leaks or frees too early.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

var keep = [];
var registry = new FinalizationRegistry(function () {});
var refs = [];

function round(r) {
    for (var i = 0; i < 2000; i++) {
        var o = {};
        var a = [];
        switch (i % 7) {
            case 0: o.s = 'str' + r + '_' + i; break;                      // counted string
            case 1: for (var k = 0; k < 12; k++) o['p' + k] = k; break;     // property block
            case 2: o.x = 1; delete o.x; o.y = 'y' + i; break;              // private shape
            case 3: a.push('e' + i, i); break;                              // string element
            case 4: registry.register(o, i); break;                         // weak interest
            case 5: refs.push(new WeakRef(o)); break;
            case 6: Object.create(o).probe; break;                          // prototype use
        }
        if (i % 97 === 0) keep.push({ o: o, a: a, tag: 'keep' + r + '_' + i });
    }
    if (refs.length > 400) refs.length = 0;
}

for (var r = 0; r < 60; r++) round(r);

var bad = 0;
for (var j = 0; j < keep.length; j++) {
    var e = keep[j];
    if (e.tag.indexOf('keep') !== 0) bad++;
    var kind = Number(e.tag.split('_')[1]) % 7;
    if (kind === 0 && e.o.s.indexOf('str') !== 0) bad++;
    if (kind === 1 && e.o.p11 !== 11) bad++;
    if (kind === 2 && (e.o.y.indexOf('y') !== 0 || 'x' in e.o)) bad++;
    if (kind === 3 && e.a[0].indexOf('e') !== 0) bad++;
}
eq(bad, 0, 'survivors keep their values');
eq(keep.length, 60 * 21, 'survivor count');

print('gc_page_teardown: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
