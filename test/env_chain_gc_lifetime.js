// GC lifetime of a captured scope CHAIN.
//
// A scope chain link is an EnvRecord: pool-allocated, never collected. Its
// `bindings` object, though, is an ordinary heap node. The object-graph marker
// used to mark only the INNERMOST link it could reach — func.var_env.bindings,
// func.lex_env.bindings, gen.var_env/lex_env.bindings and a GeneratorState's
// var_env/lex_env — and never walked EnvRecord.parent. So a closure suspended
// over `outer -> middle -> inner` survived a sweep with inner.bindings intact
// and outer.bindings freed and recycled into the object pool. The next GETVAR
// that walked past `inner` read a recycled block: ASAN reported use-after-poison
// in HObject.get_shape <- find_prop_idx on the env-chain walk, under
// drain_microtasks. mark_activation_envs already walked the full chain for LIVE
// frames, which is why only closures resumed AFTER a GC — async bodies and
// .then handlers — could hit it.
//
// This is a GC timing bug: the collection has to land while the closure is
// suspended, so the chains below are deliberately long and allocate on every
// link (the GC trigger scales with the live-object count). The reads must also
// target a variable two or more scopes out — an innermost-scope read was always
// rooted and is exactly what made the bug invisible for so long.
//
// Every assertion runs inside a microtask, where a throw exits 0 in this
// engine, so failures are reported via the stdout marker instead.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

var pending = 0, finished = 0;

// Allocation churn, so a collection lands inside the suspended window rather
// than at a quiet point between tests.
function churn(n) {
    var sink = null;
    for (var i = 0; i < n; i++) { sink = { a: i, b: [i, i + 1], c: "s" + i }; }
    return sink;
}

// --- 1. async function reading an outer-scope variable across an await ---
// `outer` lives three scopes up from the block that reads it after resuming.
function makeAsyncReader(tag) {
    var outer = tag + "-outer";            // scope A (function scope)
    {
        let middle = tag + "-middle";      // scope B (block)
        return async function () {         // closure captures B -> A -> global
            {
                let inner = tag + "-inner";   // scope C
                await Promise.resolve(churn(60));
                // Resumed after a possible sweep. Reads span C, B and A.
                return inner + "|" + middle + "|" + outer;
            }
        };
    }
}

// --- 2. plain .then handler reading two scopes out, invoked post-GC ---
function makeThenReader(tag) {
    var outer = tag + "-o";                // scope A
    {
        let middle = tag + "-m";           // scope B
        return function (v) {
            churn(40);
            return v + "/" + middle + "/" + outer;
        };
    }
}

// --- 3. generator suspended over an outer scope, resumed after churn ---
function makeGen(tag) {
    var outer = tag + "-g";                // scope A
    {
        let middle = tag + "-h";           // scope B
        return function* () {
            let inner = tag + "-i";        // scope C
            yield inner;
            churn(50);
            yield middle;                  // read after a suspension
            churn(50);
            yield outer;                   // two scopes out, latest resume
        };
    }
}

// --- 4. async generator: GeneratorState.var_env/lex_env chain across awaits ---
function makeAsyncGen(tag) {
    var outer = tag + "-ag";               // scope A
    {
        let middle = tag + "-bg";          // scope B
        return async function* () {
            let inner = tag + "-cg";       // scope C
            yield inner;
            await Promise.resolve(churn(40));
            yield middle;
            await Promise.resolve(churn(40));
            yield outer;
        };
    }
}

var GROUPS = 40;

for (var g = 0; g < GROUPS; g++) {
    (function (g) {
        var tag = "t" + g;

        // 1. async function
        pending++;
        makeAsyncReader(tag)().then(function (v) {
            assert(v === tag + "-inner|" + tag + "-middle|" + tag + "-outer",
                   "async outer-scope read g=" + g + " got " + v);
            finished++;
        });

        // 2. then handler
        pending++;
        Promise.resolve("v" + g).then(makeThenReader(tag)).then(function (v) {
            assert(v === "v" + g + "/" + tag + "-m/" + tag + "-o",
                   "then outer-scope read g=" + g + " got " + v);
            finished++;
        });

        // 3. generator, stepped from inside microtasks so a GC can land between
        // resumes while the generator's own scope chain is the only root.
        pending++;
        var it = makeGen(tag)();
        var got = [];
        got.push(it.next().value);
        Promise.resolve().then(function () {
            churn(60);
            got.push(it.next().value);
            return Promise.resolve();
        }).then(function () {
            churn(60);
            got.push(it.next().value);
            assert(got[0] === tag + "-i" && got[1] === tag + "-h" && got[2] === tag + "-g",
                   "generator outer-scope read g=" + g + " got " + got.join(","));
            finished++;
        });

        // 4. async generator
        pending++;
        (async function () {
            var ag = makeAsyncGen(tag)();
            var seen = [];
            for (var k = 0; k < 3; k++) {
                var r = await ag.next();
                seen.push(r.value);
            }
            assert(seen[0] === tag + "-cg" && seen[1] === tag + "-bg" && seen[2] === tag + "-ag",
                   "async generator outer-scope read g=" + g + " got " + seen.join(","));
            finished++;
        })();
    })(g);
}

var polls = 0;
function report() {
    if (finished < pending && polls++ < 200000) {
        Promise.resolve().then(report);
        return;
    }
    assert(finished === pending, "only " + finished + "/" + pending + " groups settled");
    print('env_chain_gc_lifetime: ' + pass + ' passed, ' + fail + ' failed');
    if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
}
report();
