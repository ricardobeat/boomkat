// Generic constraints and defaults: `extends` bounding a type parameter,
// keyof-based constraints, defaults, and constraint chains.
interface Lengthwise {
  length: number;
}
function logLen<T extends Lengthwise>(v: T): number {
  return v.length;
}
function getProp<T, K extends keyof T>(obj: T, key: K): T[K] {
  return obj[key];
}
function merge<T = { id: number }, U = { tag: string }>(a: T, b: U): T & U {
  return { ...a, ...b };
}
type Flattened<T extends unknown[]> = T[number];
const nums: Flattened<number[][]> = 3;
function smallest<T extends { value: number }>(items: T[]): T {
  let best = items[0];
  for (const it of items) if (it.value < best.value) best = it;
  return best;
}
console.log(logLen("abcd"), logLen([1, 2]), logLen({ length: 9 }));
console.log(getProp({ a: 1, b: "two" }, "b"));
const m = merge({ id: 2 }, { tag: "t" });
console.log(m.id + m.tag, merge({ id: 1 }, { tag: "x" }).tag, nums);
console.log(smallest([{ value: 3 }, { value: 1 }, { value: 2 }]).value);
