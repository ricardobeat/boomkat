// using declarations: disposal timing, order, error folding, for-head forms.
function assert(cond, msg) { if (!cond) throw new Error(msg); }

function res(name, log, hook) {
  var r = { name: name };
  r[Symbol.dispose] = function () {
    log.push(name);
    if (hook) hook();
  };
  return r;
}

function bad(name, message) {
  var r = { name: name };
  r[Symbol.dispose] = function () { throw new Error(message); };
  return r;
}

// Resources dispose in reverse order at the end of the block.
var log = [];
{
  using a = res("a", log);
  using b = res("b", log);
  log.push("body");
}
assert(log.join() === "body,b,a", "block order: " + log.join());

// A nullish resource is allowed and nothing is called for it.
log = [];
{
  using a = null;
  using b = undefined;
  using c = res("c", log);
}
assert(log.join() === "c", "nullish resources: " + log.join());

// A non-object, or an object without a callable @@dispose, is a TypeError at
// the declaration.
var caught = null;
try { { using x = 42; } } catch (e) { caught = e; }
assert(caught instanceof TypeError, "a primitive resource is a TypeError");
caught = null;
try { { using x = {}; } } catch (e) { caught = e; }
assert(caught instanceof TypeError, "a resource without @@dispose is a TypeError");
caught = null;
try { { using x = { [Symbol.dispose]: 1 }; } } catch (e) { caught = e; }
assert(caught instanceof TypeError, "a non-callable @@dispose is a TypeError");

// The method getter is read once; the method is called with the resource as
// the receiver and no arguments.
var reads = 0;
var calls = [];
var obj = {};
Object.defineProperty(obj, Symbol.dispose, {
  get: function () {
    reads++;
    return function () { calls.push([this, arguments.length]); };
  }
});
{
  using x = obj;
}
assert(reads === 1, "@@dispose read once, read " + reads + " times");
assert(calls.length === 1, "the disposer ran once");
assert(calls[0][0] === obj, "the resource is the receiver");
assert(calls[0][1] === 0, "the disposer takes no arguments");

// The binding is constant.
caught = null;
try {
  {
    using x = res("x", log);
    x = 1;
  }
} catch (e) { caught = e; }
assert(caught instanceof TypeError, "a using binding cannot be reassigned");

// The body's error is thrown as is, after the resources have been disposed.
log = [];
caught = null;
try {
  {
    using a = res("a", log);
    throw new Error("body");
  }
} catch (e) { caught = e; }
assert(caught instanceof Error && caught.message === "body", "the body error is thrown as is");
assert(!(caught instanceof SuppressedError), "a lone failure is not wrapped");
assert(log.join() === "a", "the resource was disposed on the throw: " + log.join());

// Failures during disposal fold into a chain of SuppressedErrors: the failure
// that lands last is the error, the one it displaced is the suppressed value.
log = [];
caught = null;
try {
  {
    using a = bad("a", "A");
    using b = bad("b", "B");
    throw new Error("body");
  }
} catch (e) { caught = e; }
assert(caught instanceof SuppressedError, "the failures fold: " + caught);
assert(caught.error.message === "A", "the outer error is the last failure: " + caught.error);
assert(caught.suppressed instanceof SuppressedError, "the displaced failure is a SuppressedError");
assert(caught.suppressed.error.message === "B", "the inner error is the earlier failure");
assert(caught.suppressed.suppressed.message === "body", "the body error is suppressed last");

// A return completes through the disposal and keeps its value.
function ret() {
  using a = res("ret", log);
  return 7;
}
log = [];
assert(ret() === 7, "return keeps its value");
assert(log.join() === "ret", "return disposes: " + log.join());

// break and continue run the disposal too.
log = [];
for (var i = 0; i < 3; i++) {
  using a = res("iter" + i, log);
  if (i === 1) continue;
  if (i === 2) break;
}
assert(log.join() === "iter0,iter1,iter2", "loop exits dispose: " + log.join());

// A C-style for head owns one resource, released when the loop ends.
log = [];
var j = 0;
for (using x = res("head", log); j < 3; j++) {
  log.push("body" + j);
}
assert(log.join() === "body0,body1,body2,head", "for-head disposal: " + log.join());

// for (using x of it) disposes each value at the end of the iteration, and on
// an abrupt exit it disposes before the iterator is closed.
function makeIter(values, log) {
  var k = 0;
  return {
    [Symbol.iterator]: function () { return this; },
    next: function () {
      return k < values.length ? { value: values[k++], done: false } : { value: undefined, done: true };
    },
    return: function () { log.push("close"); return { value: undefined, done: true }; }
  };
}
log = [];
for (using v of makeIter([res("v0", log), res("v1", log)], log)) {
  log.push("body");
}
assert(log.join() === "body,v0,body,v1", "per-iteration disposal: " + log.join());

log = [];
for (using v of makeIter([res("v0", log), res("v1", log)], log)) {
  log.push("body");
  break;
}
assert(log.join() === "body,v0,close", "disposal before the iterator closes: " + log.join());

// A function body disposes when the function returns; a generator body when
// the generator completes.
function fn() {
  using a = res("fn", log);
  log.push("fn body");
}
log = [];
fn();
assert(log.join() === "fn body,fn", "function body disposal: " + log.join());

function* gen() {
  using a = res("gen", log);
  yield 1;
  yield 2;
}
log = [];
var g = gen();
g.next();
g.next();
assert(log.join() === "", "a live generator holds its resource: " + log.join());
g.next();
assert(log.join() === "gen", "generator body disposal: " + log.join());

// A for-of head owns the iterator as well as the resource, and the resource is
// released first: breaking or returning closes the iterator after the release.
function oneIterable(value, events) {
  var done = false;
  return {
    [Symbol.iterator]: function () { return this; },
    next: function () {
      if (done) return { value: undefined, done: true };
      done = true;
      return { value: value, done: false };
    },
    return: function () {
      events.push("close");
      return { value: undefined, done: true };
    }
  };
}

log = [];
for (using v of oneIterable(res("v", log), log)) {
  log.push("body");
  break;
}
assert(log.join() === "body,v,close", "break: release then close: " + log.join());

function retFromLoop() {
  log = [];
  for (using v of oneIterable(res("v", log), log)) {
    return "ret";
  }
}
assert(retFromLoop() === "ret", "return keeps its value");
assert(log.join() === "v,close", "return: release then close: " + log.join());

// Nested loops: the inner iteration is released and closed before the outer
// one is.
log = [];
outer: for (using a of oneIterable(res("a", log), log)) {
  for (using b of oneIterable(res("b", log), log)) {
    log.push("body");
    break outer;
  }
}
assert(log.join() === "body,b,close,a,close", "nested order: " + log.join());

// A registration failure still closes the iterator (the iteration was
// abandoned, nothing was registered).
log = [];
caught = null;
try {
  for (using v of oneIterable({}, log)) { log.push("body"); }
} catch (e) { caught = e; }
assert(caught instanceof TypeError, "a resource without @@dispose is a TypeError");
assert(log.join() === "close", "a registration failure closes: " + log.join());

// A .next() failure does not close the iterator (§14.7.5.6 step 9.c is a `?`).
log = [];
caught = null;
var nextThrows = {
  [Symbol.iterator]: function () { return this; },
  next: function () { throw new Error("next"); },
  return: function () { log.push("close"); return { value: undefined, done: true }; }
};
try {
  for (using v of nextThrows) { log.push("body"); }
} catch (e) { caught = e; }
assert(caught.message === "next", "a .next() failure propagates");
assert(log.join() === "", "a .next() failure does not close: " + log.join());

// Normal completion of an iteration and a continue both release without
// closing; a failing disposer on either path does close.
log = [];
for (using v of oneIterable(res("normal", log), log)) {}
assert(log.join() === "normal", "normal completion: " + log.join());

log = [];
for (using v of oneIterable(res("cont", log), log)) { continue; }
assert(log.join() === "cont", "continue: " + log.join());

function failingIterable(events, disposeError, closeError) {
  var resource = { [Symbol.dispose]: function () { events.push("dispose"); if (disposeError) throw new Error(disposeError); } };
  var done = false;
  return {
    [Symbol.iterator]: function () { return this; },
    next: function () {
      if (done) return { value: undefined, done: true };
      done = true;
      return { value: resource, done: false };
    },
    return: function () {
      events.push("close");
      if (closeError) throw new Error(closeError);
      return { value: undefined, done: true };
    }
  };
}

log = [];
caught = null;
try {
  for (using v of failingIterable(log, "dispose-failure", "close-failure")) {}
} catch (e) { caught = e; }
assert(log.join() === "dispose,close", "a failing disposer closes: " + log.join());
assert(caught.message === "dispose-failure", "the disposer failure wins: " + caught);

log = [];
caught = null;
try {
  for (using v of failingIterable(log, "dispose-failure", "close-failure")) { continue; }
} catch (e) { caught = e; }
assert(log.join() === "dispose,close", "a failing disposer on continue closes: " + log.join());
assert(caught.message === "dispose-failure", "the disposer failure wins on continue: " + caught);

// Body throw, then a failing disposer, then a failing close: the disposer's
// failure displaces the body's, and the close's displaces neither (§7.4.9
// steps 6-7 keep the throw completion).
log = [];
caught = null;
try {
  for (using v of failingIterable(log, "dispose-failure", "close-failure")) {
    throw new Error("body-failure");
  }
} catch (e) { caught = e; }
assert(log.join() === "dispose,close", "throw order: " + log.join());
assert(caught instanceof SuppressedError, "the failures fold: " + caught);
assert(caught.error.message === "dispose-failure", "the disposer failure is the error");
assert(caught.suppressed.message === "body-failure", "the body failure is suppressed");

log = [];
caught = null;
try {
  for (using v of failingIterable(log, null, "close-failure")) {
    throw new Error("body-failure");
  }
} catch (e) { caught = e; }
assert(log.join() === "dispose,close", "clean dispose, failing close: " + log.join());
assert(caught.message === "body-failure", "the throw completion wins over the close: " + caught);

// A use-before-initialization read of the head binding is a ReferenceError, and
// the iterator still closes.
log = [];
caught = null;
var tdzIterable = {
  [Symbol.iterator]: function () {
    try { v; } catch (e) { log.push("tdz:" + (e instanceof ReferenceError)); }
    return oneIterable(res("v", log), log);
  }
};
try {
  for (using v of tdzIterable) {}
} catch (e) { caught = e; }
assert(log.join() === "tdz:true,v", "the head binding is in its TDZ during GetIterator: " + log.join());

// `using` stays an ordinary identifier wherever a declaration cannot start:
// the keyword introduces one only when a binding identifier follows it.
var using = { x: 0 };
log = [];
for (using.x of [1, 2]) log.push(using.x);
assert(log.join() === "1,2", "member head off the identifier using: " + log.join());
var n = 0;
for (using = 0; using < 2; using++) n++;
assert(n === 2 && using === 2, "c-style head over the identifier using");
log = [];
for (using in { key: 1 }) log.push(using);
assert(log.join() === "key", "for-in over the identifier using: " + log.join());
caught = null;
try { new Function("for (using x; ;) break;"); } catch (e) { caught = e; }
assert(caught instanceof SyntaxError, "a using head needs an initializer");

// A using declaration is not allowed at the top level of a script or of eval
// code, but it is allowed inside a block and inside a function body.
caught = null;
try { eval("using x = null;"); } catch (e) { caught = e; }
assert(caught instanceof SyntaxError, "no using at the top level of eval");
assert(new Function("using x = null;") instanceof Function, "using is fine in a function body");
caught = null;
try { new Function("if (1) using x = null;"); } catch (e) { caught = e; }
assert(caught instanceof SyntaxError, "no using as a sub-statement");
caught = null;
try { new Function("switch (1) { case 1: using x = null; }"); } catch (e) { caught = e; }
assert(caught instanceof SyntaxError, "no using in a case clause");
caught = null;
try { new Function("using x;"); } catch (e) { caught = e; }
assert(caught instanceof SyntaxError, "a using binding needs an initializer");

// A for-of declaration may not start with `using of`: there `using` is the
// identifier. Only a three-clause for declares a binding named `of`.
var forOfUsing = new Function("var using, out = []; for (using of [7]) out.push(using);"
    + " for (using in { k: 0 }) out.push(using); return out.join();");
assert(forOfUsing() === "7,k", "for (using of xs) iterates into the identifier using");
assert(new Function("{ for (using of = null;;) break; }") instanceof Function,
    "for (using of = init;;) declares a binding named of");

print("using declarations ok");
