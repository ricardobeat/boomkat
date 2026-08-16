// any, unknown, never: annotations, an unknown value narrowed before use,
// and never in an empty-union position.
const raw: any = { deep: { v: 41 } };
raw.arbitrary = raw.deep.v + 1;
function reveal(v: unknown): string {
  if (typeof v === "number") return "num:" + v;
  if (Array.isArray(v)) return "arr:" + v.length;
  return String(v);
}
type Never = string & number;
type Empty = never;
function fail(): never {
  throw new Error("stop");
}
try {
  fail();
} catch (e) {
  console.log("caught:", (e as Error).message);
}
console.log(raw.arbitrary, reveal(3), reveal([1, 2]), reveal("x"));
console.log(typeof raw, typeof reveal(0));
