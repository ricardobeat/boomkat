// this parameters, call signatures, and construct signatures: annotating
// the receiver, an object type with a call signature, `new () => T`, and an
// abstract construct signature.
interface Boxed {
  width: number;
}
function area(this: Boxed): number {
  return this.width * 2;
}
const boxed = { width: 3, area };
type Describer = {
  (label: string): string;
  weight: number;
};
const describe: Describer = (() => "x") as any;
type Ctor = new (label: string) => { label: string };
type AbsCtor = abstract new (v: number) => { v: number };
class Labeled {
  label: string;
  constructor(label: string) {
    this.label = label;
  }
}
function make(c: Ctor, s: string): string {
  return new c(s).label;
}
abstract class BaseV {
  v: number;
  constructor(v: number) {
    this.v = v;
  }
}
const withArea = boxed.area();
console.log(withArea, make(Labeled as unknown as Ctor, "tag"));
console.log(typeof describe === "function");
