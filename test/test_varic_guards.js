// Exercise every variable IC fill path. All fills now route through
// var_ic_fill, which writes the full guard set (env, bindings, shape_id,
// recycle_epoch, key, search_head, varref_store_ok) together; a fill that
// omitted recycle_epoch or key would leave a stale value that a reader for
// that field could trust. Shape-recycle churn between warm accesses forces
// the epoch to advance so a stale entry must be rejected, not served.
var pass = 0, total = 0;
function check(cond, label) {
    total++;
    if (cond) { pass++; } else { print("FAIL: " + label); }
}

// Bump the shape-recycle epoch by creating and discarding many distinct
// shapes, so shape ids get handed back out and reused.
function churn() {
    var o;
    for (var i = 0; i < 2000; i++) {
        o = {};
        o["k" + (i % 50)] = i;   // ~50 distinct shapes recycled
    }
    return o;
}

// GETGLOBAL + PUTGLOBAL in a loop (global read/write ICs).
var g = 0;
churn();
for (var i = 0; i < 100000; i++) { g = g + 1; }
check(g === 100000, "global inc loop after churn");

// MOVE_GG: `a = b` between two globals, both directions.
var ga = 7, gb = 0;
churn();
for (var i = 0; i < 100000; i++) { gb = ga; ga = gb; }
check(ga === 7 && gb === 7, "MOVE_GG loop after churn");

// JMP_LT_G: compare a register against a global inside a loop.
var limit = 50000;
var n = 0;
churn();
for (var i = 0; i < 100000; i++) { if (i < limit) n++; }
check(n === 50000, "JMP_LT_G loop after churn");

// INC_VAR / DEC_VAR on a function-local env variable.
function counter() {
    var c = 0;
    for (var i = 0; i < 100000; i++) { c++; }
    for (var i = 0; i < 50000; i++) { c--; }
    return c;
}
churn();
check(counter() === 50000, "INC_VAR/DEC_VAR loop after churn");

// DECLVAR: repeated function calls re-declaring a var (no env leak).
function decl() {
    var d = 1;
    d += 2;
    return d;
}
churn();
var acc = 0;
for (var i = 0; i < 100000; i++) { acc += decl(); }
check(acc === 300000, "DECLVAR repeated calls after churn");

// Warm the ICs, then churn shapes, then keep reading: a stale entry whose
// shape id was recycled must be rejected.
var warm = 42;
for (var i = 0; i < 100; i++) { warm = warm + 1; }
churn();
check(warm === 142, "warmed IC survives shape churn");

// Two globals written alternately: each site's IC must not cross-pollinate.
var alt_a = 0, alt_b = 0;
for (var i = 0; i < 100000; i++) {
    alt_a = alt_a + 1;
    alt_b = alt_b + 2;
}
check(alt_a === 100000 && alt_b === 200000, "alternating global ICs stay separate");

// A global read through a function (GETVAR across the env chain) stays warm.
var shared = 3;
function read_shared() { return shared; }
var sacc = 0;
churn();
for (var i = 0; i < 100000; i++) { sacc += read_shared(); }
check(sacc === 300000, "closure env read after churn");

print("test_varic_guards: " + pass + " passed, " + (total - pass) + " failed");
