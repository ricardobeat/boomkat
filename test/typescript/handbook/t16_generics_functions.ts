// Generics on functions: a type parameter used in parameters and return,
// explicit type arguments at the call site, and inference from arguments.
function first<T>(items: T[]): T | undefined {
  return items[0];
}
function pair<K, V>(k: K, v: V): [K, V] {
  return [k, v];
}
function pickBy<T, U>(items: T[], key: (item: T) => U): U[] {
  const out: U[] = [];
  for (const it of items) out.push(key(it));
  return out;
}
console.log(first([true, false]), first<string>(["x", "y"]), first([]) === undefined);
const p = pair("k", 7);
console.log(p[0] + p[1]);
console.log(pickBy([1, 2, 3], (n) => "v" + n).join("|"));
