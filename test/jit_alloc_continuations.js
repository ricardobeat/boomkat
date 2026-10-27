function resumeAssert(value, expected) {
    if (value !== expected) throw new Error('native continuation: ' + value + ' != ' + expected);
}
function ResumePair(left, right) { this.left = left; this.right = right; }
function resumeAllocate(n) {
    var total = 0;
    for (var i = 0; i < n; i++) {
        var object = { left: i, right: i + 1 };
        var pair = new ResumePair(object, i);
        var array = [pair, object];
        var constants = [2, 3, 5];
        total += array[0].right + array[1].right + constants[1];
    }
    return total;
}
function resumeAppend(array, n) {
    for (var i = 0; i < n; i++) array.push(i);
    return array.length;
}
for (var warm = 0; warm < 80; warm++) {
    resumeAssert(resumeAllocate(32), 1120);
    resumeAssert(resumeAppend([], 32), 32);
}
resumeAssert(resumeAllocate(1000), 1003000);
var resumeValues = [];
resumeAssert(resumeAppend(resumeValues, 4096), 4096);
for (var i = 0; i < resumeValues.length; i++) resumeAssert(resumeValues[i], i);

// A prototype setter, frozen length, or replaced intrinsic must take the
// ordinary call path without applying an append first.
var resumeSetters = 0;
Object.defineProperty(Array.prototype, '0', {
    configurable: true, set: function (value) { resumeSetters++; resumeAssert(value, 0); }
});
var resumeIntercepted = [];
resumeAssert(resumeAppend(resumeIntercepted, 1), 1);
resumeAssert(resumeSetters, 1);
delete Array.prototype[0];
resumeAssert(Object.prototype.hasOwnProperty.call(resumeIntercepted, '0'), false);
var resumeFrozen = Object.freeze([]), resumeThrows = 0;
try { resumeAppend(resumeFrozen, 1); } catch (e) { resumeThrows++; }
resumeAssert(resumeThrows, 1);
resumeAssert(resumeFrozen.length, 0);
var resumeCustom = [];
resumeCustom.push = function (value) { this.calls = (this.calls || 0) + 1; };
resumeAssert(resumeAppend(resumeCustom, 3), 0);
resumeAssert(resumeCustom.calls, 3);
console.log('JIT allocation continuations: PASS');
