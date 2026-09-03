// Generator.prototype.throw/return/next do not finish synchronously. They
// rewrite the callee register with a wrapper around the generator's compiled
// body and set ctx.needs_re_dispatch, asking the VM's CALL handling to
// re-dispatch so the body actually resumes.
//
// Every call/apply/bind indirection site in builtins/function.c3 built its own
// nested inner_ctx, dispatched the real target into it, and propagated only
// inner_ctx.should_throw -- inner_ctx.needs_re_dispatch was dropped. The same
// gap existed in the two BUILTIN_FN re-dispatch handlers in vm/vm_calls.c3
// that a bound function reaches. Either way the generator never resumed and
// the call evaluated to undefined instead of an IteratorResult.
//
// Expected values are node's (runs unmodified under node with `--import` a
// shim defining print()).

var failures = 0;
var checks = 0;

function eq(name, actual, expected) {
    checks++;
    if (actual !== expected) {
        failures++;
        print("FAIL: " + name + " => " + JSON.stringify(actual) +
              " (expected " + JSON.stringify(expected) + ")");
    }
}

function* catching() {
    try {
        yield 1;
    } catch (e) {
        yield e;
    }
}

var GeneratorObjectPrototype = Object.getPrototypeOf(function* () {}).prototype;
var GenThrow = GeneratorObjectPrototype.throw;
var GenNext = GeneratorObjectPrototype.next;
var GenReturn = GeneratorObjectPrototype.return;

// (a) .throw via .call -- the injected exception is caught by the generator's
// own try/catch, which then yields it back out.
var g1 = catching();
GenNext.call(g1);
eq("throw.call result", JSON.stringify(GenThrow.call(g1, 99)),
   '{"value":99,"done":false}');

// (b) .throw via .bind, with the thrown value pre-bound. This reaches the
// builtin through the BOUND_CALL dispatcher, one extra layer of indirection.
var g2 = catching();
g2.next();
var boundThrow = GenThrow.bind(g2, 42);
eq("throw.bind result", JSON.stringify(boundThrow()),
   '{"value":42,"done":false}');

// (c) .throw via .apply, both with and without an argument array.
var g3 = catching();
g3.next();
eq("throw.apply result", JSON.stringify(GenThrow.apply(g3, [5])),
   '{"value":5,"done":false}');

// (d) .next via .call and .bind -- same re-dispatch mechanism.
var g4 = catching();
eq("next.call first", JSON.stringify(GenNext.call(g4)),
   '{"value":1,"done":false}');

var g5 = catching();
var boundNext = GenNext.bind(g5);
eq("next.bind first", JSON.stringify(boundNext()),
   '{"value":1,"done":false}');
// JSON.stringify omits an undefined-valued property entirely.
eq("next.bind exhausts", JSON.stringify(boundNext()), '{"done":true}');

// (e) .return via .call and .bind. return on a suspended generator runs no
// further body code here (no finally), so it completes with the sent value.
var g6 = catching();
g6.next();
eq("return.call result", JSON.stringify(GenReturn.call(g6, 7)),
   '{"value":7,"done":true}');

var g7 = catching();
g7.next();
var boundReturn = GenReturn.bind(g7, 8);
eq("return.bind result", JSON.stringify(boundReturn()),
   '{"value":8,"done":true}');

// (f) After an indirect throw is caught and re-yielded, the generator is still
// live and drains normally through the direct path.
var g8 = catching();
g8.next();
GenThrow.call(g8, "caught");
eq("post-throw drain", JSON.stringify(g8.next()), '{"done":true}');

// (g) A throw injected into a generator with no handler still propagates out
// of the indirect call as a real exception rather than returning undefined.
function* bare() { yield 1; }
var g9 = bare();
g9.next();
var propagated = null;
try {
    GenThrow.call(g9, "boom");
} catch (e) {
    propagated = e;
}
eq("unhandled throw propagates", propagated, "boom");

if (failures === 0) {
    print("PASS generator_throw_via_call_bind (" + checks + " checks)");
} else {
    print("FAILURES: " + failures);
    throw new Error("generator_throw_via_call_bind failed");
}
