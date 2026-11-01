// Constant bits survive helper calls, phi edges and recovery after stores.
function check(ok, name) { if (!ok) throw new Error(name); }
function specialRemat(output, callback, count) {
    var minusZero = -0.0, nan = 0 / 0, positive = 1 / 0, negative = -1 / 0;
    var i = 0;
    do {
        var answer = callback();
        output[0] = minusZero;
        output[1] = nan;
        output[2] = positive;
        output[3] = negative;
        var coerced = answer + 1;
        i++;
    } while (i < count);
    return coerced;
}
function checkSpecials(output) {
    check(1 / output[0] === -Infinity && output[1] !== output[1]
        && output[2] === Infinity && output[3] === -Infinity, 'special values');
}
var calls = 0, conversions = 0, output = [0, 0, 0, 0];
function ordinary() { calls++; return 7; }
for (var warm = 0; warm < 160; warm++) {
    check(specialRemat(output, ordinary, 2) === 8, 'warm');
}
function late() {
    calls++;
    return { valueOf: function() { conversions++; return 7; } };
}
var before = calls;
check(specialRemat(output, late, 2) === 8, 'late coercion');
check(calls === before + 2 && conversions === 2, 'once');
checkSpecials(output);
function throwing() {
    calls++;
    return { valueOf: function() { conversions++; throw 'special'; } };
}
before = calls;
try { specialRemat(output, throwing, 1); throw 'missing'; }
catch (error) { check(error === 'special', 'throw'); }
check(calls === before + 1 && conversions === 3, 'exact callback and coercion counts');
checkSpecials(output);
console.log('special constant helper/deopt: PASS');
