interface Named { name: string }
interface Aged { age: number }
interface Person extends Named, Aged { role: string }
let p: Person = { name: "a", age: 1, role: "x" };
print(p.name);
print(p.age);
print(p.role);
