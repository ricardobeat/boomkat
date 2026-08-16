// Type assertions: `as T`, the double hop through unknown, non-null `!`
// after property access and after an index, and `as` on a return value.
const raw: unknown = "text";
const len = (raw as string).length;
const force = raw as unknown as number;
function find(id: number): { name: string } | null {
  return id === 1 ? { name: "one" } : null;
}
const box: { v?: string } = {};
type MaybeNum = number | undefined;
const m: MaybeNum = undefined;
const arr: (string | null)[] = ["a", null, "b"];
console.log(len, force === ("text" as unknown as number));
console.log(find(1)!.name.length, arr[2]!.length);
try {
  const boom = find(2)!.name;
  console.log("unreachable", boom);
} catch (e) {
  console.log("caught:", (e as TypeError).name);
}
console.log(box.v?.length ?? "unset", m ?? -1);
