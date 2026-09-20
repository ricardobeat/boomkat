function equal(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' !== ' + expected);
}
function assertThrows(source, kind) {
    var caught = false;
    try { Function(source)(); } catch (e) { caught = e instanceof kind; }
    if (!caught) throw new Error('wrong exception: ' + source);
}
function loop() {
    let sum = 0;
    for (let i = 0; i < 100; i++) {
        const x = i;
        const {a, b} = {a: x, b: 2};
        if (i === 3) continue;
        sum += a + b;
    }
    return sum;
}
equal(loop(), 5145);
var writes = ['x = 2', 'x += 2', 'x++', '++x', 'x--', '--x',
              'x &&= 2', 'x ||= 2', 'x ??= 2'];
for (var i = 0; i < writes.length; i++) {
    var initial = writes[i] === 'x ||= 2' ? '0' : writes[i] === 'x ??= 2' ? 'null' : '1';
    assertThrows('const x = ' + initial + '; ' + writes[i], TypeError);
}
assertThrows('const x = x;', ReferenceError);
assertThrows('x(); const x = 1;', ReferenceError);
assertThrows('typeof x; const x = 1;', ReferenceError);
assertThrows('x = 2; const x = 1;', ReferenceError);
assertThrows('const x = (x = 2);', ReferenceError);
equal(Function('const x = 1; return delete x;')(), false);
equal(Function('const x = 1; return eval("x");')(), 1);
assertThrows('const x = 1; eval("x = 2")', TypeError);
function capture() {
    let result = [];
    for (let i = 0; i < 3; i++) { const x = i; result.push(() => x); }
    return result[0]() + 10 * result[1]() + 100 * result[2]();
}
equal(capture(), 210);
function shadow() {
    const x = 1;
    { const x = 2; equal(x, 2); }
    return x;
}
equal(shadow(), 1);
var sideEffects = 0;
function assignWithSideEffect() { const x = 1; x = ++sideEffects; }
var assignmentThrew = false;
try { assignWithSideEffect(); } catch (e) { assignmentThrew = e instanceof TypeError; }
equal(assignmentThrew, true);
equal(sideEffects, 1);
function unwind() {
    let result = 0;
    outer: for (let i = 0; i < 5; i++) {
        const x = i;
        try {
            const y = x + 1;
            if (i === 1) continue;
            if (i === 3) break outer;
            result += y;
        } finally { const z = 10; result += z; }
    }
    return result;
}
equal(unwind(), 44);
// More name-based uses than the compiler's small dependency buffer must retain
// the later TDZ and const checks too.
var source = '';
for (var j = 0; j < 70; j++) source += 'typeof missing' + j + ';';
assertThrows(source + 'const x = 1; x = 2;', TypeError);
assertThrows(source + 'const x = x;', ReferenceError);
function retainedObject() {
    const held = {value: 17};
    for (let i = 0; i < 3000; i++) { const garbage = {value: i}; }
    return held.value;
}
equal(retainedObject(), 17);
function throughWith() {
    const held = 17;
    with ({held: 23}) { equal(held, 23); }
    return held;
}
equal(throughWith(), 17);
print('register const environments: PASS');
