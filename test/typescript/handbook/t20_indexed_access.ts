// Indexed access types: T[K] over objects, arrays, tuples, interfaces, and
// indexing one type with the keyof of another.
type Pt = { x: number; y: string };
type X = Pt["x"];
type Y = Pt["y"];
type Arr = boolean[];
type Elem = Arr[number];
type Tup = [string, number, { deep: boolean }];
type T0 = Tup[0];
type T2d = Tup[2]["deep"];
interface Window2 {
  title: string;
  panes: number;
}
type P = Window2["panes"];
const x: X = 5;
const y: Y = "s";
const e: Elem = true;
const d: T2d = false;
const p: P = 3;
function get<T, K extends keyof T>(o: T, k: K): T[K] {
  return o[k];
}
console.log(x, y, e, d, p);
console.log(get({ n: 1, s: "v" }, "n"), get({ n: 1, s: "v" }, "s") + "!");
