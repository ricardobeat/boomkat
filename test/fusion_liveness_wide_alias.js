// Fusion liveness: a branch's operand bytes must never be read as a register.
//
// The shared dead-after-liveness scan (fusion_reg_live_from in
// compiler/fusion.c3) walks forward from a fusion's consumer looking for the
// next read or overwrite of the scratch register. It recognised an overwrite
// as "this instruction's A field names the scratch register" — but the WIDE
// formats (JUMP/BREAK/CONTINUE) have no A field at all: they pack a 24-bit
// signed branch offset across A/B/C, so A is the offset's LOW BYTE.
//
// A `JUMP +3` therefore looked exactly like a write to register 3, ending the
// scan early and reporting a still-live register dead. Reporting a live
// register dead is the UNSAFE direction: it permits a fusion that bakes the
// scratch value away while a later instruction still reads it.
//
// Measured over test262: 212 liveness scans terminated on precisely this alias
// (211 JUMP, 1 BREAK) and 17 files' fused bytecode changed once the guard was
// added. cmp_result_live_from and run_move_gg_fusion's scan already carried the
// guard; the shared helper was the one copy that omitted it.
//
// SCOPE OF THIS TEST — read before assuming a failure here means a miscompile.
// No known input produces a WRONG VALUE from the missing guard, because the
// shapes that trigger it are also shapes where fusion_abc_reads_reg's
// conservative treatment of CALL's C field (an argument COUNT, not a register)
// independently pins the same register live. The two errors cancel. This test
// therefore locks in the OBSERVABLE BEHAVIOUR of the shapes that sit on that
// path, so that if either side is later changed — the WIDE guard removed, or
// the CALL carve-out widened as the comment in fusion_abc_reads_reg
// contemplates — the cancellation cannot silently become a real miscompile.
// The bytecode-level assertion lives in test/golden_bytecode/.

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; }
    else { fail++; print('FAIL: ' + msg); }
}

function eq(actual, expected, msg) {
    assert(actual === expected, msg + ' (got ' + actual + ', want ' + expected + ')');
}

// --- The shape whose fused bytecode actually changes: a computed property key
// built from a ternary (so a JUMP closes the true arm), read back through a
// member call whose argument list re-reads the same scratch register. This is
// the minimised form of the test262 file that first exposed the alias.
var probe = {
    same: function (a, b) { return a === b; },
    pick: function (a, b, c) { return [a, b, c].join('/'); }
};

var keyed = { [true ? 1 : 2]: 'T', [false ? 3 : 4]: 'F' };

eq(probe.same(keyed[true ? 1 : 2], 'T'), true, 'computed ternary key, true arm');
eq(probe.same(keyed[false ? 3 : 4], 'F'), true, 'computed ternary key, false arm');
eq(probe.same(keyed[String(true ? 1 : 2)], 'T'), true, 'computed ternary key via String()');
eq(probe.pick(keyed[true ? 1 : 2], keyed[false ? 3 : 4], 'z'), 'T/F/z',
   'two computed ternary keys in one argument list');

// --- ADDI/SUBI trigger: an LDINT scratch consumed by arithmetic and then read
// AGAIN after an if/else join. The JUMP closing the true arm is the WIDE op the
// scan used to stop on.
function arith_across_join(c) {
    var k = 4;
    var a;
    if (c) { a = k + 1; } else { a = 9; }
    return a + k;
}
eq(arith_across_join(1), 9, 'ADDI scratch live across if/else join, true arm');
eq(arith_across_join(0), 13, 'ADDI scratch live across if/else join, false arm');

function sub_across_join(c) {
    var k = 6;
    var a;
    if (c) { a = k - 2; } else { a = 20; }
    return a - k;
}
eq(sub_across_join(1), -2, 'SUBI scratch live across if/else join, true arm');
eq(sub_across_join(0), 14, 'SUBI scratch live across if/else join, false arm');

// --- Register-depth sweep. The alias between a JUMP's offset byte and a
// register number only occurs at particular depths, so one depth proves
// nothing.
function depth_sweep(depth, c) {
    var p0 = 0, p1 = 1, p2 = 2, p3 = 3, p4 = 4, p5 = 5, p6 = 6, p7 = 7;
    var used = 0;
    if (depth > 0) { used += p0 + p1 + p2 + p3 + p4 + p5 + p6 + p7; }
    var k = 3;
    var a;
    if (c) { a = k + 1; } else { a = 8; }
    return a + k + (used === 0 ? 0 : 0);
}
for (var d = 0; d < 8; d++) {
    eq(depth_sweep(d, 1), 7, 'depth ' + d + ' true arm');
    eq(depth_sweep(d, 0), 11, 'depth ' + d + ' false arm');
}

// --- Ternary in operand position with the scratch reused after the join.
function tern_operand(c) {
    var k = 5;
    var v = (c ? 10 : 20) + k;
    return v + k;
}
eq(tern_operand(1), 20, 'ternary left operand, scratch reused after join');
eq(tern_operand(0), 30, 'ternary right operand, scratch reused after join');

// --- GETPROPC trigger: an LDCONST key scratch that must survive a join.
var obj = { a: 1, b: 2, c: 3 };
function prop_across_join(c) {
    var key = 'a';
    var t = obj[key];
    var r;
    if (c) { r = obj.b; } else { r = obj.c; }
    return r + t + obj[key];
}
eq(prop_across_join(1), 4, 'GETPROPC scratch live across join, true arm');
eq(prop_across_join(0), 5, 'GETPROPC scratch live across join, false arm');

// --- BREAK and CONTINUE are the other two WIDE-format opcodes.
function loop_with_break(n) {
    var k = 2;
    var acc = 0;
    for (var i = 0; i < n; i++) {
        if (i === 3) { break; }
        acc += k;
    }
    return acc + k;
}
eq(loop_with_break(2), 6, 'loop scratch live past BREAK, no break taken');
eq(loop_with_break(9), 8, 'loop scratch live past BREAK, break taken');

function loop_with_continue(n) {
    var k = 3;
    var acc = 0;
    for (var i = 0; i < n; i++) {
        if (i % 2 === 0) { continue; }
        acc += k;
    }
    return acc + k;
}
eq(loop_with_continue(4), 9, 'loop scratch live past CONTINUE');
eq(loop_with_continue(7), 12, 'loop scratch live past CONTINUE, longer');

// --- Labeled loops emit the widest offsets, so their low byte covers the most
// register numbers.
function labeled(n) {
    var k = 4;
    var acc = 0;
    outer: for (var i = 0; i < n; i++) {
        for (var j = 0; j < n; j++) {
            if (j > i) { continue outer; }
            if (i === 3 && j === 2) { break outer; }
            acc += k;
        }
    }
    return acc + k;
}
eq(labeled(3), 28, 'labeled loop scratch live past CONTINUE/BREAK');
eq(labeled(5), 36, 'labeled loop scratch live past CONTINUE/BREAK, wider');

// --- Compound assignment: the scratch is read and written each iteration.
function compound(n) {
    var k = 3;
    var s = 5;
    for (var i = 0; i < n; i++) {
        if (i % 2) { s += k; } else { s -= 1; }
    }
    return s + k;
}
eq(compound(4), 12, 'compound assignment scratch across branchy loop body');
eq(compound(5), 11, 'compound assignment scratch across branchy loop body, odd n');

// --- MOVE_GG axis: run_move_gg_fusion used to carry its own hand-copied
// liveness scan; it now calls the shared helper. Global-to-global copies
// interleaved with branches exercise it.
var ga = 1, gb = 2, gc = 3;
function move_gg_driver(n) {
    var out = [];
    for (var i = 0; i < n; i++) {
        if (i % 2) { ga = gb; } else { gb = gc; }
        gc = i;
        out.push(ga + '/' + gb + '/' + gc);
    }
    return out.join('|');
}
eq(move_gg_driver(4), '1/3/0|3/3/1|3/1/2|1/1/3', 'MOVE_GG pair across a branchy loop');

print('fusion_liveness_wide_alias: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
