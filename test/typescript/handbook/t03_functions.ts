// Function annotations: parameters, return types, function-type expressions,
// optional and default parameters, rest parameters, and void returns.
function add(x: number, y: number): number {
  return x + y;
}
const mul: (a: number, b: number) => number = (a, b) => a * b;
function greet(name: string, punct?: string): string {
  return "hi " + name + (punct ?? "!");
}
function shout(msg: string, level: number = 2): string {
  return msg.toUpperCase() + "!".repeat(level);
}
function tally(first: number, ...rest: number[]): number {
  let sum = first;
  for (const r of rest) sum += r;
  return sum;
}
function logIt(v: number): void {
  console.log("void:", v);
}
console.log(add(2, 3), mul(4, 5));
console.log(greet("ann"), greet("bob", "?"));
console.log(shout("hey"), shout("hey", 3));
console.log(tally(1), tally(1, 2, 3, 4));
logIt(9);
