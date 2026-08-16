// Assertion functions: `asserts x is T` signatures, called for the side
// effect of narrowing. The signature erases; the body is plain JS.
function assertIsString(val: unknown): asserts val is string {
  if (typeof val !== "string") {
    throw new Error("not a string: " + typeof val);
  }
}
function assertDefined<T>(val: T | null | undefined): asserts val is T {
  if (val == null) {
    throw new Error("nullish");
  }
}
const a: unknown = "word";
assertIsString(a);
console.log(a.length);
const b: number | null = 4;
assertDefined(b);
console.log(b * 2);
try {
  assertIsString(3);
} catch (e) {
  console.log("caught:", (e as Error).message);
}
