// Regression: the compare->branch fusion's bridge correction treated ANY
// forward IF_FALSE/IF_TRUE sitting at the branch target as an `&&`/`||`
// continuation and extended the fused offset past it. When the loop body's
// first statement is a bare truthiness test on a register-resident local
// (`for (var j = 0; j < n; j++) { if (j) ... }`), the back-edge target IS an
// IF_FALSE — on an unrelated register. The back-edge was moved one branch
// deeper, into the else arm, so every iteration after the first re-executed
// only that arm and the result was a constant stale value.
//
// The correction only applies when the continuation reads the compare's own
// result register (rA), which is the register the fusion stops materializing.

var pass = 0;
var fail = 0;

function assert(actual, expected, name) {
    if (actual === expected) {
        pass++;
    } else {
        fail++;
        print('FAIL ' + name + ': expected ' + expected + ' got ' + actual);
    }
}

// --- bare `if (j)` as the first body statement, every loop/step form ---

function f_for(n) { var r = ''; for (var j = 0; j < n; j++) { if (j) { r += '2' } else { r += '3' } } return r }
assert(f_for(3), '322', 'for j++');

function f_for_pre(n) { var r = ''; for (var j = 0; j < n; ++j) { if (j) { r += '2' } else { r += '3' } } return r }
assert(f_for_pre(3), '322', 'for ++j');

function f_for_pluseq(n) { var r = ''; for (var j = 0; j < n; j += 1) { if (j) { r += '2' } else { r += '3' } } return r }
assert(f_for_pluseq(3), '322', 'for j+=1');

function f_for_assign(n) { var r = ''; for (var j = 0; j < n; j = j + 1) { if (j) { r += '2' } else { r += '3' } } return r }
assert(f_for_assign(3), '322', 'for j=j+1');

function f_while(n) { var r = ''; var j = 0; while (j < n) { if (j) { r += '2' } else { r += '3' } j++ } return r }
assert(f_while(3), '322', 'while j++');

function f_dowhile(n) { var r = ''; var j = 0; do { if (j) { r += '2' } else { r += '3' } j++ } while (j < n); return r }
assert(f_dowhile(3), '322', 'do-while j++');

// Countdown: the counter is truthy on every iteration, so a stale back-edge
// yields a constant '333' instead of '222'.
function f_down(n) { var r = ''; for (var j = n; j > 0; j--) { if (j) { r += '2' } else { r += '3' } } return r }
assert(f_down(3), '222', 'for j--');

function f_down_pre(n) { var r = ''; for (var j = n; j > 0; --j) { if (j) { r += '2' } else { r += '3' } } return r }
assert(f_down_pre(3), '222', 'for --j');

// --- other bare-truthiness result forms ---

function f_tern(n) { var r = ''; for (var j = 0; j < n; j++) { r += j ? '2' : '3' } return r }
assert(f_tern(3), '322', 'ternary condition');

function f_andor(n) { var r = ''; for (var j = 0; j < n; j++) { r += (j && '2') || '3' } return r }
assert(f_andor(3), '322', '&&/|| condition');

// --- shapes that were already correct; guard against over-correcting ---

function f_strict(n) { var r = ''; for (var j = 0; j < n; j++) { if (j !== 0) { r += '2' } else { r += '3' } } return r }
assert(f_strict(3), '322', 'if (j !== 0)');

function f_neg(n) { var r = ''; for (var j = 0; j < n; j++) { if (!j) { r += '3' } else { r += '2' } } return r }
assert(f_neg(3), '322', 'if (!j)');

function f_compound(n) { var r = ''; for (var j = 0; j < n; j++) { if (j && 1) { r += '2' } else { r += '3' } } return r }
assert(f_compound(3), '322', 'if (j && 1)');

// A genuine `&&` bridge: the continuation reads the compare's own result
// register, so the correction must still fire here.
function caesar(text) {
    var out = '';
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i);
        if (c >= 65 && c <= 90) { out += String.fromCharCode((c - 65 + 3) % 26 + 65) }
        else if (c >= 97 && c <= 122) { out += String.fromCharCode((c - 97 + 3) % 26 + 97) }
        else { out += text[i] }
    }
    return out;
}
assert(caesar('Hello, World!'), 'Khoor, Zruog!', 'and-continuation bridge still fused');

// --- nested and labeled loops (a two-word fusion's offset must carry over
// unchanged, and flat loops can pass while nested ones fail) ---

function f_nest2() { var r = ''; for (var i = 0; i < 2; i++) { for (var j = 0; j < 2; j++) { if (j) { r += '2' } else { r += '3' } } } return r }
assert(f_nest2(), '3232', 'nested 2 deep');

function f_nest3() { var r = ''; for (var i = 0; i < 2; i++) { for (var j = 0; j < 2; j++) { for (var k = 0; k < 2; k++) { if (k) { r += '2' } else { r += '3' } } } } return r }
assert(f_nest3(), '32323232', 'nested 3 deep');

function f_lab_cont() {
    var r = '';
    outer: for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 3; j++) {
            if (j) { r += '2' } else { r += '3' }
            if (j === 2) { continue outer }
        }
    }
    return r;
}
assert(f_lab_cont(), '322322', 'labeled continue');

function f_lab_break() {
    var r = '';
    outer: for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 3; j++) {
            if (j) { r += '2' } else { r += '3' }
            if (j === 2) { break outer }
        }
    }
    return r;
}
assert(f_lab_break(), '322', 'labeled break');

function f_lab_self() {
    var r = '';
    L: for (var j = 0; j < 4; j++) {
        if (j) { r += '2' } else { r += '3' }
        if (j === 1) { continue L }
    }
    return r;
}
assert(f_lab_self(), '3222', 'labeled continue on the same loop');

// --- body with an inner loop and extra statements ---

function f_inner_loop(n) {
    var r = '';
    for (var j = 0; j < n; j++) {
        if (j) { r += '2' } else { r += '3' }
        for (var k = 0; k < 2; k++) { r += '.' }
    }
    return r;
}
assert(f_inner_loop(3), '3..2..2..', 'body with inner loop');

function f_multi(n) {
    var r = '';
    for (var j = 0; j < n; j++) {
        var t = 1;
        if (j) { r += '2' } else { r += '3' }
        r += '';
    }
    return r;
}
assert(f_multi(3), '322', 'multi-statement body');

// Nested if inside the bare-truthiness arm.
function f_nested_if(n) {
    var r = '';
    for (var j = 0; j < n; j++) {
        if (j) { if (1) { r += '2' } else { r += '9' } } else { r += '3' }
    }
    return r;
}
assert(f_nested_if(3), '322', 'nested if in the true arm');

print('loop_backedge_bare_truthiness: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
