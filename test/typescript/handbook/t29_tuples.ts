// Tuples: fixed positions, named elements, optional trailing elements, rest
// elements, readonly tuples, and destructuring them.
type Point = [number, number];
type Named = [name: string, age: number];
type Opt = [first: string, second?: number];
type Rest = [head: number, ...tail: number[]];
type Locked = readonly [string, number];
const p: Point = [1, 2];
const n: Named = ["ann", 31];
const o: Opt = ["solo"];
const r: Rest = [1, 2, 3, 4];
const l: Locked = ["a", 1];
const [x, y] = p;
const [head, ...tail] = r;
const [name2] = n;
function dist(pt: Point): number {
  return pt[0] * pt[0] + pt[1] * pt[1];
}
console.log(p.join(","), n.join(":"), o.length, l.join("-"));
console.log(x, y, head, tail.join("+"), name2, dist([3, 4]));
