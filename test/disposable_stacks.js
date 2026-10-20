// DisposableStack: calling conventions, disposal order, error folding.
function assert(cond, msg) { if (!cond) throw new Error(msg); }

// use() hands the resource to its dispose method as the receiver; adopt() and
// defer() call a callback with an undefined receiver, and adopt() passes the
// value as the argument.
var seen = [];
var stack = new DisposableStack();
var resource = {
  closed: false,
  [Symbol.dispose]() { seen.push(["use", this, arguments.length]); this.closed = true; }
};
assert(stack.use(resource) === resource, "use returns the value");
stack.adopt("adopted", function (v) { seen.push(["adopt", this, arguments.length, v]); });
stack.defer(function () { seen.push(["defer", this, arguments.length]); });

assert(stack.disposed === false, "a fresh stack is not disposed");
stack.dispose();
assert(stack.disposed === true, "the stack is disposed after dispose()");
assert(resource.closed === true, "the resource was disposed");
assert(seen.length === 3, "every resource was disposed");
// The records dispose in reverse order, so the deferred callback ran first.
assert(seen[0][0] === "defer", "defer: the callback ran");
assert(seen[0][2] === 0, "defer: the callback takes no argument");
assert(seen[1][0] === "adopt", "adopt: the callback ran");
assert(seen[1][2] === 1 && seen[1][3] === "adopted", "adopt: the value is the argument");
assert(seen[2][0] === "use" && seen[2][1] === resource, "use: the resource is the receiver");
assert(seen[2][2] === 0, "use: the method takes no argument");

// Disposal runs in reverse order.
var order = [];
var s2 = new DisposableStack();
s2.defer(function () { order.push(1); });
s2.defer(function () { order.push(2); });
s2.defer(function () { order.push(3); });
s2.dispose();
assert(order.join() === "3,2,1", "reverse order: " + order.join());

// A failing disposer folds into a SuppressedError: the failure that comes last
// in disposal order is the outer error, the one it displaced is suppressed.
var s3 = new DisposableStack();
s3.defer(function () { throw new TypeError("older"); });
s3.defer(function () { throw new RangeError("newer"); });
var caught = null;
try { s3.dispose(); } catch (e) { caught = e; }
assert(caught instanceof SuppressedError, "the failures fold into a SuppressedError");
assert(caught.error instanceof TypeError, "the last failure is the error");
assert(caught.suppressed instanceof RangeError, "the earlier failure is suppressed");

// A single failure is thrown as is.
var s4 = new DisposableStack();
s4.defer(function () { throw new RangeError("alone"); });
caught = null;
try { s4.dispose(); } catch (e) { caught = e; }
assert(caught instanceof RangeError && !(caught instanceof SuppressedError), "thrown as is");

// move() hands the resources to a fresh stack and disposes the old one.
var moved = null;
var s5 = new DisposableStack();
s5.use(resource);
moved = s5.move();
assert(moved instanceof DisposableStack, "move returns a stack");
assert(s5.disposed === true, "the source is disposed");
moved.dispose();
assert(resource.closed === true, "the moved resource is disposed by the new stack");

// A nullish value is not a resource, and a disposed stack rejects new ones.
var s6 = new DisposableStack();
s6.use(null);
s6.use(undefined);
s6.dispose();
var threw = false;
try { s6.use({ [Symbol.dispose]() {} }); } catch (e) { threw = e instanceof ReferenceError; }
assert(threw, "use on a disposed stack throws a ReferenceError");

console.log("ok");
