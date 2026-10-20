// Same shape as dep.js, reached through a dynamic import so the importing
// module can assert on the settlement order.
export let disposed = false;

await using resource = {
  async [Symbol.asyncDispose]() {
    await 0;
    await 0;
    await 0;
    disposed = true;
  }
};
export { resource };
