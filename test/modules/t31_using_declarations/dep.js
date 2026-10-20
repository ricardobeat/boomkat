// A dependency's top-level `await using` is disposed before its evaluation
// promise settles, so the importing module already sees it disposed.
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

if (disposed) {
  throw new Error("resource disposed before module evaluation completed");
}
