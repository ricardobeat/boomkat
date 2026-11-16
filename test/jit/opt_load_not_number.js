// A field that holds a string is read into a register that only a never-run addition uses: the
// optimized body must stop loading it as a number after the first exit instead of exiting forever.

function pick(e, q) {
    const x = e._x, order = e._order;
    switch (order) {
        case 'XYZ': q.v = x * 2; break;
        case 'YXZ': q.v = x * 3; break;
        default: q.v = 'unknown order: ' + order;
    }
    return q;
}

var e = { _x: 1.5, _order: 'XYZ' }, q = { v: 0 };
for (var i = 0; i < 200000; i++) pick(e, q);
console.log(q.v);
e._order = 'YXZ';
for (var i = 0; i < 1000; i++) pick(e, q);
console.log(q.v);
e._order = 7;
console.log(pick(e, q).v);

// The same through an element and a null field.
function sum(a, o) {
    var v = a[1], t = o.start;
    if (t !== null) return t + v.length;
    return typeof v === 'string' ? v.length : v - 1;
}
var arr = [1, 'abc', 3], o = { start: null }, s = 0;
for (var i = 0; i < 200000; i++) s += sum(arr, o);
console.log(s);
o.start = 4;
console.log(sum(arr, o));
