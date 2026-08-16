// Narrowing with typeof: guard in a condition, combined guards, and a
// narrowing function applied through a ternary.
function padLeft(value: string, padding: string | number): string {
  if (typeof padding === "number") {
    return " ".repeat(padding) + value;
  }
  return padding + value;
}
function total(x: string | number | boolean): string {
  if (typeof x === "string") return x.length + "ch";
  if (typeof x === "boolean") return x ? "yes" : "no";
  return x + "?";
}
const vals: (string | number | boolean)[] = ["ab", 3, true, "cdef"];
console.log(padLeft("x", 3), padLeft("x", ">>"));
for (const v of vals) console.log(total(v));
