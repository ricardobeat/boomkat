// An angle-bracket assertion erases the type and keeps the expression.
const value = <number>42;
const list = <string[]>["a", "b"];
const nothing = <undefined>undefined;
console.log(value, list.length, nothing);

function identity<T>(input: T): T {
  return input;
}
const generic = <T>(input: T): T => input;
console.log(identity("x"), generic(7));

const cast = <{ a: number }>{ a: 1 };
console.log(cast.a);
