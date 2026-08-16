// Primitive type annotations: string, number, boolean, literal-initialized
// bindings, and annotated reassignment (TS Handbook, Everyday Types).
let done: boolean = false;
let count: number = 10;
let name: string = "boxes";
count += 5;
name += "!";
const frozen: number = 1;
console.log(done, count, name, frozen);
console.log(typeof done, typeof count, typeof name);
