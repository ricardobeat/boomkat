// AsyncDisposableStack: the await rules, the sync @@dispose fallback and the
// error folding.
function assert(cond, msg) { if (!cond) throw new Error(msg); }

// An empty stack resolves without an extra await: the promise is already
// fulfilled when disposeAsync returns, so the caller's continuation is
// already queued.
var empty = new AsyncDisposableStack();
var seq = [];
await Promise.all([
  Promise.resolve().then(() => { seq.push("job 1"); }),
  empty.disposeAsync().then(() => { seq.push("dispose"); }),
  Promise.resolve().then(() => { seq.push("job 2"); })
]);
assert(seq.join() === "job 1,dispose,job 2", "empty stack: " + seq.join());

// A nullish resource is not disposed, but the stack still awaits once.
var nullish = new AsyncDisposableStack();
nullish.use(null);
seq = [];
await Promise.all([
  Promise.resolve().then(() => 0).then(() => { seq.push("job 1"); }),
  nullish.disposeAsync().then(() => { seq.push("dispose"); }),
  Promise.resolve().then(() => 0).then(() => { seq.push("job 2"); })
]);
assert(seq.join() === "job 1,dispose,job 2", "nullish resource: " + seq.join());

// The calling conventions match the sync stack.
var seen = [];
var conventions = new AsyncDisposableStack();
conventions.use({
  async [Symbol.asyncDispose]() { seen.push(["use", this, arguments.length]); }
});
conventions.adopt("adopted", function (v) { seen.push(["adopt", this, arguments.length, v]); });
conventions.defer(function () { seen.push(["defer", this, arguments.length]); });
await conventions.disposeAsync();
assert(seen.length === 3, "every resource was disposed");
assert(seen[0][0] === "defer" && seen[0][2] === 0, "defer: no argument");
assert(seen[1][0] === "adopt" && seen[1][2] === 1 && seen[1][3] === "adopted", "adopt: the value is the argument");
assert(seen[2][0] === "use" && seen[2][2] === 0, "use: the method takes no argument");

// A sync @@dispose on an async stack still disposes with async semantics: the
// method runs, and the value it returns is discarded rather than awaited.
var disposed = false;
var never = new Promise(function () {});
var fallback = new AsyncDisposableStack();
fallback.use({ [Symbol.dispose]() { disposed = true; return never; } });
await fallback.disposeAsync();
assert(disposed === true, "the sync disposer ran");

// A failing disposer folds into a SuppressedError.
var failing = new AsyncDisposableStack();
failing.defer(async function () { throw new TypeError("older"); });
failing.defer(async function () { throw new RangeError("newer"); });
var caught = null;
try { await failing.disposeAsync(); } catch (e) { caught = e; }
assert(caught instanceof SuppressedError, "the failures fold into a SuppressedError");
assert(caught.error instanceof TypeError, "the last failure is the error");
assert(caught.suppressed instanceof RangeError, "the earlier failure is suppressed");

// A second disposeAsync resolves without disposing again.
var once = new AsyncDisposableStack();
var count = 0;
once.defer(function () { count++; });
await once.disposeAsync();
await once.disposeAsync();
assert(count === 1, "the resource is disposed once");

console.log("ok");
