// Intersection types: combining objects, a value satisfying both members,
// and intersection with a primitive alias.
type Named = { name: string };
type Aged = { age: number };
type Person = Named & Aged;
type Mixed = Named & string;
const p: Person = { name: "kim", age: 31 };
function describe(v: Person): string {
  return v.name + ":" + v.age;
}
type Confident = Person & { sure: boolean };
const c: Confident = { name: "lee", age: 9, sure: true };
console.log(describe(p), p.name.length, c.sure);
