// Function overloads: a signature list with a typed implementation last
// (each signature ends with `;` via line break), including an overload pair
// distinguished only by parameter types.
function pick(name: "a" | "b", fn: (prev: (x: number) => number) => (x: number) => number): void;
function pick(name: "c", fn: (prev: (x: string) => string) => (x: string) => string): void;
function pick(
  name:
    | "a"
    | "b"
    | "c",
  fn: (prev: any) => any,
): void {
  console.log("picked:", name, fn.length);
}
pick("a", (f) => f);
pick("c", (f) => f);
function makeDate(timestamp: number): Date;
function makeDate(y: number, m: number, d: number): Date;
function makeDate(a: number, b?: number, c?: number): Date {
  return b === undefined ? new Date(a) : new Date(a, b - 1, c);
}
console.log(makeDate(70, 0, 1).getTime() === makeDate(0).getTime());
console.log(makeDate(2020, 1, 2).getUTCFullYear?.() >= 1970 || true);
