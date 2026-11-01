// Available expressions must describe this dynamic iteration, and a store
// through another descriptor may alias any earlier load on any CFG path.
var effectsPad = "var q0=0,q1=0,q2=0,q3=0,q4=0,q5=0,q6=0,q7=0,q8=0,q9=0," +
    "q10=0,q11=0,q12=0,q13=0,q14=0,q15=0,q16=0,q17=0,q18=0,q19=0," +
    "q20=0,q21=0,q22=0,q23=0,q24=0;";
function EffectsBox() { this.step = 2; }
EffectsBox.prototype.scalar = new Function("n", effectsPad +
    "var s=q0,i=0; while(i<n){ var a=(i*3+1)|0; var b=(i*3+1)|0; s=s+a+b; i=i+1; } return s;");
EffectsBox.prototype.alias = new Function("a", "b", "n", effectsPad +
    "var s=q0,i=0; while(i<n){ var x=a.x; if(i&1){ b.x=b.x+1; } s=s+x+a.x; i=i+1; } return s;");
EffectsBox.prototype.backedge = new Function("a", "b", "n", effectsPad +
    "var s=q0,i=0; while(i<n){ s=s+a.x; b.x=b.x+1; i=i+1; } return s;");
EffectsBox.prototype.forward = new Function("a", "n", effectsPad +
    "var s=q0,i=0; while(i<n){ a.x=a.x+1; s=s+a.x; i=i+1; } return s;");
EffectsBox.prototype.receivers = new Function("a", "b", "n", effectsPad +
    "var s=q0,i=0; while(i<n){ var o; if(i&1){ o=a; }else{ o=b; } s=s+o.x+o.x; i=i+1; } return s;");
EffectsBox.prototype.recover = new Function("a", "n", effectsPad +
    "var s=q0,i=0; while(i<n){ a.x=a.x+1; s=s+this.step; i=i+1; } return s;");
var effectsBox = new EffectsBox();
var effectsChecksum = 0;
for (var warm = 0; warm < 400; warm++) {
    var n = 9 + (warm & 3);
    var scalar = effectsBox.scalar(n);
    if (scalar !== 3*n*(n-1)+2*n) throw Error("scalar iteration identity");
    var a = {x: 3}, b = {x: 11};
    var separate = effectsBox.alias(a, b, n);
    if (separate !== 6*n || a.x !== 3 || b.x !== 11+(n>>1)) throw Error("separate descriptor store");
    a.x = 3;
    var together = effectsBox.alias(a, a, n);
    var expected = 0, current = 3;
    for (var i = 0; i < n; i++) { var old = current; if (i&1) current++; expected += old+current; }
    if (together !== expected || a.x !== current) throw Error("aliased branch store");
    a.x = 3;
    var carried = effectsBox.backedge(a, a, n);
    if (carried !== 3*n+n*(n-1)/2 || a.x !== 3+n) throw Error("backedge memory version");
    a.x = 3;
    var forwarded = effectsBox.forward(a, n);
    if (forwarded !== 3*n+n*(n+1)/2 || a.x !== 3+n) throw Error("store forwarding");
    var receivers = effectsBox.receivers({x: 5}, {x: 19}, n);
    if (receivers !== 10*(n>>1)+38*((n+1)>>1)) throw Error("receiver iteration identity");
    a.x = 0;
    if (effectsBox.recover(a, n) !== 2*n || a.x !== n) throw Error("warm recovery");
    effectsChecksum += scalar+separate+together+carried+forwarded+receivers;
}
// A cold conversion after a published write must observe that write exactly
// once. A guard cannot recover at an earlier frame or replay a prior store.
var recoveryTarget = {x: 0}, recoveryCalls = 0, recoverySeen = 0;
effectsBox.step = {valueOf: function () {
    recoveryCalls++;
    recoverySeen += recoveryTarget.x;
    return 2;
}};
if (effectsBox.recover(recoveryTarget, 5) !== 10 || recoveryTarget.x !== 5 ||
    recoveryCalls !== 5 || recoverySeen !== 15) throw Error("published store recovery order");
print("jit cyclic effects ok " + effectsChecksum);
