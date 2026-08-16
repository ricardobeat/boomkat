// Conditional types and infer: nested conditionals across line breaks (the
// shape every real-world library uses), infer in extends clauses, infer in
// tuple rest positions, and distributive behavior.
type IsString<T> = T extends string ? "yes" : "no";
type ElementOf<T> = T extends (infer U)[] ? U : never;
type Head<T> = T extends [infer H, ...any[]] ? H : never;
type Flatten<T> = T extends Array<infer U> ? Flatten<U> : T;
type Unwrap<T> = T extends Promise<infer V> ? Unwrap<V> : T;
type DeepRead<T> = T extends object
  ? { readonly [K in keyof T]: DeepRead<T[K]> }
  : T;
type Mutate<S, Ms> = number extends Ms["length"]
  ? S
  : Ms extends []
    ? S
    : Ms extends [[infer Mi, infer Ma], ...infer Mrs]
      ? Mutate<Ma, Mrs>
      : never;
type A = IsString<"x">;
type B = IsString<3>;
type C = ElementOf<string[]>;
type D = Head<[number, string]>;
type E = Flatten<number[][]>;
type F = Unwrap<Promise<Promise<number>>>;
type G = DeepRead<{ a: { b: number } }>;
type H = Mutate<{ v: 1 }, [[string, { v: 2 }], [number, { v: 3 }]]>;
const a: A = "yes";
const b: B = "no";
const c: C = "s";
const d: D = 1;
const e: E = 5;
const f: F = 6;
const g: G = { a: { b: 1 } };
const h: H = { v: 3 };
console.log(a, b, c, d, e, f, g.a.b, h.v);
