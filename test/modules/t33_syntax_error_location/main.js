// Test 33: import() of a module that fails to parse rejects with a SyntaxError
// whose stack names the file, line and column, also when the failing module
// is a dependency of the one imported.

for (const spec of ["./bad.js", "./via.js"]) {
  let err;
  await import(spec).catch((e) => { err = e; });
  if (!(err instanceof SyntaxError)) throw new Error(spec + ": expected a SyntaxError, got " + err);
  if (!/^SyntaxError: /.test(err.stack)) throw new Error(spec + ": bad stack header: " + err.stack);
  if (!/\n    at \S*bad\.js:2:\d+$/.test(err.stack)) throw new Error(spec + ": stack lacks location: " + err.stack);
}
