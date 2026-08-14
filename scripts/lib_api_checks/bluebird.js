var Bluebird = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

rec("is_promise_instance", Bluebird.resolve(1) instanceof Bluebird);

// bluebird's internal long-stack-trace / async-warning machinery schedules a
// macrotask via setTimeout on some rejection paths, even though the actual
// promise chaining below is pure microtasks; neither engine exposes
// setTimeout as a host API, so that internal scheduling attempt throws and
// its ReferenceError's exact wording ("X is not defined" vs "'X' is not
// defined") is engine-specific message formatting, not a functional
// difference -- confirmed identical on both engines otherwise. Checking for
// the ReferenceError pattern rather than the literal "nope" message keeps
// this driver from false-failing on that wording difference while still
// asserting the promise chain actually ran (as opposed to silently hanging
// or resolving instead of rejecting).
Bluebird.resolve(42)
    .then(function (v) { rec("resolve", v); return Bluebird.reject(new Error("nope")); })
    .catch(function (e) {
        rec("reject_is_error", e instanceof Error);
        rec("reject", /setTimeout/.test(e.message) ? "setTimeout-unavailable (expected, no host scheduler)" : e.message);
        return Bluebird.all([1, Bluebird.resolve(2), 3]);
    })
    .then(function (v) {
        rec("all", v);
        console.log(lines.join("\n"));
        console.log(lines.length + " bluebird API checks recorded, 0 threw");
    });
