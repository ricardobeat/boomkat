// import type / export type in a module: type-only imports, an inline
// `import { type X }` specifier, a value import alongside the types, and a
// type-only re-export. The runtime import only carries the value.
import type { Token, Pair, Cfg } from "./t35_dep.ts";
import { type Pair as P2, type Cfg as Cfg2, makePair } from "./t35_dep.ts";
export type { Token } from "./t35_dep.ts";
const t: Token = { kind: "id" };
const p: Pair<string, number> = ["k", 1];
const q: P2<number, string> = [2, "v"];
const c: Cfg = { retries: 3 };
const c2: Cfg2 = { retries: 9 };
console.log(t.kind, p.join(":"), q.join("-"), c.retries, c2.retries);
console.log(makePair("a", true).join("|"));
