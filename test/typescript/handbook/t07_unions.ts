// Union types: literal unions, string|number handling, narrowing by switch
// and equality, and a union as a return type.
type Direction = "up" | "down" | "left" | "right";
function move(d: Direction): string {
  switch (d) {
    case "up":
      return "+y";
    case "down":
      return "-y";
    case "left":
      return "-x";
    default:
      return "+x";
  }
}
function format(v: string | number): string {
  if (v === "none") return "-";
  if (typeof v === "number") return "n" + v;
  return "s" + v;
}
const dir: Direction = "left";
console.log(move("up"), move(dir), move("right"));
console.log(format("none"), format(5), format("abc"));
console.log(format(Math.round(2.6)));
