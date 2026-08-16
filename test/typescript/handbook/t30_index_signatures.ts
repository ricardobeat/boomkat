// Index signatures: string-keyed records, number-keyed records, mixed with
// named properties, and Record with a union key.
type Dict = { [key: string]: number };
type ById = { [id: number]: string };
type Registry = {
  version: string;
  [name: string]: unknown;
};
type Conf = Record<"a" | "b", boolean>;
const d: Dict = { one: 1, two: 2 };
const by: ById = {};
by[7] = "seven";
const reg: Registry = { version: "1.0", extra: 5 };
const c: Conf = { a: true, b: false };
d.three = 3;
console.log(d.one + d.two + d.three, by[7], reg.version);
console.log(Object.keys(d).sort().join("|"), c.a, c.b);
