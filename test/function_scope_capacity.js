// Function scopes sized for their declared bindings.
//
// A function whose bindings live in its scope object (a closure captures
// them) declares them one by one on entry. Past four bindings the object used
// to grow after a variable cache had bound it, which moved its slots and
// retired every variable cache in the program on each call. The scope is now
// created with room for every binding it declares.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

// Many captured parameters and locals, read by a nested closure that redeclares
// its own parameters, as Scheme-compiled code does.
function wide(a, b, c, d, e, f, g, h) {
    var x = a + b, y = c + d, loop;
    loop = function (n, acc) {
        var n; var acc;
        while (n > 0) { acc = acc + x + y + e + f + g + h; n--; }
        return acc;
    };
    return loop(3, 0);
}
var total = 0;
for (var i = 0; i < 500; i++) total += wide(i, 1, 2, 3, 4, 5, 6, 7);
eq(total, 500 * 3 * (1 + 2 + 3 + 4 + 5 + 6 + 7) + 3 * 499 * 500 / 2, 'captured bindings');

// A scope that ends up with more bindings than it declares: direct eval adds
// one, and a sloppy function declaration in a block another.
function grows(p, q, r, s, t) {
    var u = 1;
    eval('var extra = p + q + r + s + t + u;');
    { function inner() { return extra; } }
    return function () { return inner() + extra; };
}
var g = 0;
for (var i = 0; i < 100; i++) g += grows(1, 2, 3, 4, i)();
eq(g, 2 * (100 * 11 + 99 * 100 / 2), 'bindings beyond the declared count');

// Globals read from inside such functions keep their caches across calls.
var counter = 0;
function bump(a, b, c, d, e) {
    var k = function () { return a + b + c + d + e; };
    counter += k();
    return counter;
}
for (var i = 0; i < 300; i++) bump(1, 1, 1, 1, 1);
eq(counter, 1500, 'global writes across calls');

print('function_scope_capacity: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
