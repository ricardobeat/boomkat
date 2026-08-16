// Mapped types: in keyof T, homomorphic modifiers (+readonly, +?), removal
// (-readonly, -?), key remapping with `as`, and mapping over a union of keys.
type Part<T> = { [K in keyof T]?: T[K] };
type Frozen<T> = { readonly [K in keyof T]: T[K] };
type Thawed<T> = { -readonly [K in keyof T]: T[K] };
type Requ<T> = { [K in keyof T]-?: T[K] };
type Getters<T> = { [K in keyof T as `get${Capitalize<string & K>}`]: () => T[K] };
type PickFew<T, K extends keyof T> = { [P in K]: T[P] };
type OnlyStatus = PickFew<{ status: number; noise: string }, "status">;
type Values<T> = { [K in keyof T]: T[K] }[keyof T];
const p: Part<{ a: number; b: string }> = { a: 1 };
const f: Frozen<{ x: number }> = { x: 1 };
const t: Thawed<{ x: number }> = { x: 2 };
const r: Requ<{ a?: number }> = { a: 3 };
const g: Getters<{ name: string; age: number }> = {
  getName: () => "ann",
  getAge: () => 31,
};
const s: OnlyStatus = { status: 7 };
const v: Values<{ a: 1; b: "two" }> = "two";
console.log(p.a, f.x, t.x, r.a, g.getName(), g.getAge(), s.status, v);
