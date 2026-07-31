// GETPROPC2 chain fusion: two adjacent GETPROPCs where the first's destination
// feeds the second's source collapse into GETPROPC2 + a data slot at i+1.
//
// The method-call form is deliberate: `o.m.z()` leaves the INTERMEDIATE temp
// (the fused GETPROPC2's A register, holding `o.m`) live after the pair, because
// it is reloaded as the call's `this`. That makes this golden pin the exact
// invariant the VM handler owes the fusion — every exit path from the GETPROPC2
// handler must write the hop-1 result back into that temp. See the behavioural
// pair in test/getpropc2_proxy_chain.js.
function twoHop(o) {
  return o.m.z();
}
twoHop({ m: { z: function () { return 1; } } });
