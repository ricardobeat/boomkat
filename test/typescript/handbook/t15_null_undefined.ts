// null and undefined: explicitly typed bindings, optional chaining that
// stops at holes, nullish coalescing with both fallbacks taken.
const maybe: string | null = Math.random() >= 0 ? "here" : null;
const absent: number | undefined = undefined;
type Holder = { inner?: { value?: number } };
const h1: Holder = { inner: { value: 6 } };
const h2: Holder = { inner: {} };
const h3: Holder = {};
console.log(maybe ?? "<null>", absent ?? -1);
console.log(h1.inner?.value ?? "none", h2.inner?.value ?? 99, h3.inner?.value ?? 0);
const list: (string | null)[] = ["a", null, "c"];
console.log(list.map((s) => s?.length ?? -1).join(","));
console.log(null ?? undefined ?? "end");
