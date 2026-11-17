// Copy propagation: an unconditional jump over a write must not kill the copy.
//
// Copy propagation (CompilerContext.finish in compiler/context.c3) NOPs
// `LDREG rT = rS` when its consumer can read rS instead and rT is dead after it.
// Its liveness scan is linear: a write to rT that only the fall-through path
// runs must not count as a kill on a path that branches past it. Conditional
// branches already pushed `join_pc` out to their target; an unconditional
// forward jump (`break`) did not, so in
//
//     b = id(n); f = b + g;
//     if (c === g) break out;   // jumps past the loop
//     while (1) { b = heap[c]; ... }   // the only write the scan saw
//     ...
//     store(b);                 // reached by the jump, reads b
//
// the copy into b was dropped and the jump arrived with b's old value.
// wasm2js output (Draco's JS decoder, Pb, a vector resize) has this shape.

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; }
    else { fail++; print('FAIL: ' + msg); }
}

function eq(actual, expected, msg) {
    assert(actual === expected, msg + ' (got ' + actual + ', want ' + expected + ')');
}

function id(x) { return x; }

function break_past_loop(b, c, g) {
    var f = 0;
    out: {
        b = id(100);
        f = b + g;
        if (c === g) { break out; }
        while (1) { b = heap[c]; c = c + 1; if (c >= 3) { break; } }
    }
    return b + ':' + f;
}
var heap = [7, 8, 9];
eq(break_past_loop(1, 4, 4), '100:104', 'break past a loop keeps the copy');
eq(break_past_loop(1, 0, 4), '9:104', 'the loop path still runs');

function labeled_blocks(a, b) {
    var c = 0, f = 0;
    a: {
        b: {
            b = id(a * 2);
            f = b + a;
            if ((c | 0) == 0) { break b; }
            while (1) { c = c - 1 | 0; b = heap[c + 3]; if ((c | 0) != -3) { continue; } break; }
            break a;
        }
        c = b;
    }
    return b + ':' + f + ':' + c;
}
eq(labeled_blocks(21, 1), '42:63:42', 'nested labeled break past a loop keeps the copy');

print('copyprop_forward_jump: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
