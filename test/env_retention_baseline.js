// Retention baseline for plans/085. Each makeClosure call captures a local, so
// the engine allocates an environment per iteration. With reclamation enabled,
// the pool returns those records after the loop; without it, live cells grow
// with the iteration count. Run under `just run` or `out/env_pool_stats`.
function makeClosure(i) {
    var x = i;
    return function () { return x; };
}
var sum = 0;
for (var i = 0; i < 100000; i++) {
    var f = makeClosure(i);
    sum += f();
}
if (sum !== 4999950000) throw new Error("sum " + sum);
