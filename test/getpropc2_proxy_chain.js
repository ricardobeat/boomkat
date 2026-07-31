// Behavioural pair for test/golden_bytecode/getpropc2_chain.expected.
//
// The golden pins the FUSED SHAPE (GETPROPC2 + data slot, with the intermediate
// temp reloaded by an LDREG after the pair); this file pins the ANSWER, so a
// regenerated golden cannot make a broken chain the contract.
//
// Regression covered: the GETPROPC2 handler's hop-2 Proxy path returned early,
// before the "store intermediate result in ra" write-back that every other exit
// path performs. The chain-fusion peephole does not check whether the temp is
// live after the pair — measured over the test262 corpus, 33399 fusions fire and
// the temp is frequently read afterwards — so it relies on the VM restoring it
// unconditionally. On the Proxy path the temp kept whatever the register held
// before, which for `o.m.z()` is the `this` passed to `z`: the method was called
// with a stale receiver instead of `o.m`.
//
// The trigger needs all three of: a two-hop chain (so the pair fuses), a *method
// call* on the second hop (so the temp is live after the pair as `this`), and a
// Proxy as the hop-1 result (so hop 2 takes the early-returning [[Get]] path).
// Reading the value alone (`o.m.z`) does NOT reproduce it.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (got " + String(actual) + ", want " + String(expected) + ")");
}

// --- the receiver passed to a method reached through a proxied second hop ---
(function () {
  var target = { z: function () { return this; } };
  var p = new Proxy(target, { get: function (t, k) { return t[k]; } });
  var o = { m: p };
  // Compared by identity rather than with eq(): String(proxy) here would
  // re-enter the get trap, so the failure message would say nothing useful.
  assert(o.m.z() === p, "method on proxied hop-2 gets the proxy as `this`");
})();

// --- repeated in a loop: the second and later iterations take the IC paths ---
(function () {
  var target = { z: function () { return this === p ? "p" : "stale"; } };
  var p = new Proxy(target, { get: function (t, k) { return t[k]; } });
  var o = { m: p };
  var acc = "";
  for (var i = 0; i < 5; i++) { acc += o.m.z(); }
  eq(acc, "ppppp", "receiver stays correct across IC-warm iterations");
})();

// --- the trap runs exactly once per chain evaluation, with the right key ---
(function () {
  var log = [];
  var target = { z: function () { return "called"; } };
  var p = new Proxy(target, { get: function (t, k) { log.push(k); return t[k]; } });
  var o = { m: p };
  eq(o.m.z(), "called", "proxied hop-2 method returns its own result");
  eq(log.join(","), "z", "get trap invoked once, for the hop-2 key only");
})();

// --- a trap that allocates heavily (drives GC) while the temp is live ---
(function () {
  var target = { z: function () { return this === p ? "p" : "stale"; } };
  var p = new Proxy(target, {
    get: function (t, k) {
      var junk = [];
      for (var i = 0; i < 2000; i++) { junk.push({ a: i, s: "s" + i }); }
      junk = null;
      return t[k];
    }
  });
  var o = { m: p };
  eq(o.m.z(), "p", "receiver survives a GC-heavy get trap");
})();

// --- plain value read through a proxied second hop ---
(function () {
  var p = new Proxy({ z: 7 }, { get: function (t, k) { return t[k]; } });
  var o = { m: p };
  eq(o.m.z, 7, "value read through a proxied hop 2");
})();

// --- the intermediate temp itself is still usable after the chain ---
(function () {
  var p = new Proxy({ z: 1 }, { get: function (t, k) { return t[k]; } });
  var o = { m: p };
  var v = o.m.z;
  eq(v, 1, "chain value");
  eq(o.m, p, "hop-1 result unchanged by the chain");
})();

// --- proxies on BOTH hops ---
(function () {
  var inner = new Proxy({ z: "deep" }, { get: function (t, k) { return t[k]; } });
  var outer = new Proxy({ m: inner }, { get: function (t, k) { return t[k]; } });
  eq(outer.m.z, "deep", "proxy on hop 1 and hop 2");
})();

// --- a revoked proxy as the hop-2 object still throws ---
(function () {
  var r = Proxy.revocable({ z: 1 }, {});
  var o = { m: r.proxy };
  r.revoke();
  var threw = false;
  try { o.m.z; } catch (e) { threw = e instanceof TypeError; }
  assert(threw, "revoked proxy on hop 2 throws TypeError");
})();

// --- a throwing get trap propagates ---
(function () {
  var p = new Proxy({}, { get: function () { throw new TypeError("trap"); } });
  var o = { m: p };
  var threw = false;
  try { o.m.z; } catch (e) { threw = e instanceof TypeError; }
  assert(threw, "throwing get trap on hop 2 propagates");
})();

// --- non-proxy control: the same shape must keep working ---
(function () {
  var o = { m: { z: function () { return this; } } };
  eq(o.m.z(), o.m, "plain two-hop method call gets the hop-1 object as `this`");
})();

print('getpropc2_proxy_chain: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
