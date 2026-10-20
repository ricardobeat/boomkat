// Fusion liveness: PUTPROP reads its object from A.
//
// fusion_abc_reads_reg (compiler/fusion.c3) reported only B and C as reads
// for any opcode without its own case. PUTPROPC had one, but plain PUTPROP,
// whose A field is the object register, did not. In
//
//     if (bd.bullet) this.m_flags |= F.bullet;
//
// LDTHIS r + GETPROPC = r fused into GETTHISC while the closing
// `PUTPROP r = key, value` still needed `this` in r. The store landed on
// whatever r held next (bd.bullet, a boolean) and silently did nothing.
// Octane's Box2D never woke its bodies, so nothing moved and it scored ~12x
// too high.

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; }
    else { fail++; print('FAIL: ' + msg); }
}

function eq(actual, expected, msg) {
    assert(actual === expected, msg + ' (got ' + actual + ', want ' + expected + ')');
}

var Body = (function () {
    var F = { bullet: 8, fixed: 16, awake: 2 };
    function Body(bd) {
        this.m_flags = 0;
        if (bd.bullet) this.m_flags |= F.bullet;
        if (bd.fixed) this.m_flags |= F.fixed;
        if (bd.awake) this.m_flags |= F.awake;
    }
    return Body;
})();
eq(new Body({ bullet: true, fixed: false, awake: true }).m_flags, 10, 'conditional flag updates on this');
eq(new Body({ bullet: false, fixed: true, awake: false }).m_flags, 16, 'only the middle flag');
eq(new Body({}).m_flags, 0, 'no flags');

var o = { k: 'n', n: 1 };
function computed_key(cond) {
    var key = o.k;
    this[key] = 0;
    if (cond) this[key] += o.n;
    return this[key];
}
eq(computed_key.call({}, true), 1, 'computed-key PUTPROP on this after a branch');

print('fusion_liveness_putprop_base: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
