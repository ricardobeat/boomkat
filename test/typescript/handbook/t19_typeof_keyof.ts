// typeof and keyof: type query from a value, keyof over object and interface
// types, keyof of an index signature, and keyof used at runtime as a plain
// value-level loop over keys.
const cfg = { host: "localhost", port: 8080, debug: true };
type Cfg = typeof cfg;
type CfgKeys = keyof Cfg;
interface Point {
  x: number;
  y: number;
}
type PointKeys = keyof Point;
type AnyKeys = keyof { [k: string]: number };
const keys: PointKeys[] = ["x", "y"];
const copy: Cfg = { host: "h", port: 1, debug: false };
function has<K extends keyof Cfg>(k: K): boolean {
  return k in cfg;
}
console.log(keys.join("+"), copy.port, has("host"), has("nope"));
console.log(Object.keys(cfg).sort().join(","));
type Fn = (a: number) => string;
type FnRet = ReturnType<typeof parseInt>;
console.log(typeof parseInt === "function");
