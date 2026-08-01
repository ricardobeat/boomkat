// A top-level `for` loop counter is a proven primitive-only global, so the
// loop-head compare reads it with the guard-free GETGLOBAL_PRIM rather than a
// guarded GETVAR. The simple-condition fast path used to emit GETVAR directly
// at global scope, which skipped the prim-slot proof for the one read that runs
// every iteration. The `while` loop below covers the same fast path in its
// other copy. `sum` stays primitive-only too, so the body reads are guard-free.
var sum = 0;
for (var i = 0; i < 4; i++) { sum += i; }

var j = 0;
while (j < 4) { sum += j; j++; }

print(sum);
