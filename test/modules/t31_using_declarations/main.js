// using and await using declarations: module-level disposal, and the release
// then close ordering of an async iteration.
import { disposed as depDisposed } from "./dep.js";

function assert(cond, msg) { if (!cond) throw new Error(msg); }

assert(depDisposed === true, "a dependency's await using is disposed before the importer runs");

var dynamic = await import("./dep2.js");
assert(dynamic.disposed === true, "a module's evaluation promise covers its top-level disposal");

var log = [];
function res(name) {
  return {
    async [Symbol.asyncDispose]() {
      await 0;
      log.push("dispose:" + name);
    }
  };
}

// An async generator's own finally reports the close, which only runs for an
// abrupt exit.
async function* loggingGen(name, values) {
  try {
    for (var i = 0; i < values; i++) yield res(name);
  } finally {
    await 0;
    log.push("close:" + name);
  }
}

async function headTests() {
  // The iteration's resource is released before the iterator is closed, and
  // both steps can await.
  for await (await using v of loggingGen("a", 2)) {
    log.push("body");
    break;
  }
  assert(log.join() === "body,dispose:a,close:a", "await using head: " + log.join());

  // Exhaustion runs each iteration's release and leaves the iterator finished
  // on its own, so the only close is the generator body's finally.
  log = [];
  for await (await using v of loggingGen("b", 2)) {
    log.push("body");
  }
  assert(log.join() === "body,dispose:b,body,dispose:b,close:b", "exhaustion: " + log.join());

  // A throw from the body releases, then closes, then propagates after both.
  log = [];
  var caught = null;
  try {
    for await (await using v of loggingGen("c", 1)) {
      throw new Error("body");
    }
  } catch (e) { caught = e; }
  assert(caught instanceof Error && caught.message === "body", "the body error propagates: " + caught);
  assert(log.join() === "dispose:c,close:c", "throw ordering: " + log.join());

  // A sync `using` head releases with sync semantics, then closes.
  log = [];
  var syncCalls = 0;
  var one = {
    [Symbol.asyncIterator]: function () { return this; },
    next: function () {
      return Promise.resolve({ value: { [Symbol.dispose]: function () { syncCalls++; log.push("sync-dispose"); } }, done: false });
    },
    return: function () {
      log.push("close");
      return Promise.resolve({ value: undefined, done: true });
    }
  };
  for await (using v of one) {
    break;
  }
  assert(syncCalls === 1, "the sync disposer ran once");
  assert(log.join() === "sync-dispose,close", "using head over an async iterator: " + log.join());

  // Exhaustion closes nothing.
  log = [];
  var done = false;
  var counting = {
    [Symbol.asyncIterator]: function () { return this; },
    next: function () {
      if (done) return Promise.resolve({ value: undefined, done: true });
      done = true;
      return Promise.resolve({ value: res("one"), done: false });
    },
    return: function () {
      log.push("close");
      return Promise.resolve({ value: undefined, done: true });
    }
  };
  for await (await using v of counting) {
    log.push("body");
  }
  assert(log.join() === "body,dispose:one", "exhaustion closes nothing: " + log.join());
}

await headTests();

// A top-level await using in this module runs when evaluation finishes.
var mainDisposals = 0;
await using mainResource = {
  async [Symbol.asyncDispose]() { mainDisposals++; }
};
assert(mainDisposals === 0, "the module's own resource is still live");

print("using declarations (modules) ok");
