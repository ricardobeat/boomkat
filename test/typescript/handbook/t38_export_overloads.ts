// Exported function overloads (the valtio unstable_replaceInternalFunction
// shape): repeated `export function` signature-only declarations ending in
// `void`, a multi-line union in one parameter list, and the implementation
// last. Signatures produce no export; the implementation binds it.
export function replace(
  name: "objectIs",
  fn: (prev: (x: number) => number) => (x: number) => number,
): void;
export function replace(
  name:
    | "objectIs"
    | "canProxy"
    | "createSnapshot",
  fn: (prev: any) => any,
): void {
  console.log("replaced:", name, typeof fn);
}
export function pick2(n: "a", f: (x: string) => string): void;
export function pick2(n: "b", f: (x: number) => number): void;
export function pick2(n: string, f: (x: any) => any): void {
  console.log("picked:", n, f.length);
}
replace("objectIs", (f) => f);
replace("canProxy", (f) => f);
pick2("a", (s) => s + "!");
pick2("b", (n) => n + 1);
