// Interfaces: property and method members, optional members, readonly
// members, extends with multiple bases, and a class implementing one.
interface Animal {
  readonly kind: string;
  name: string;
  age?: number;
  speak(volume?: number): string;
}
interface Pet extends Animal {
  owner: string;
}
interface Trained extends Pet {
  tricks: string[];
}
class Dog implements Animal {
  readonly kind = "dog";
  constructor(public_name: string) {
    this.name = public_name;
  }
  name: string;
  speak(volume = 1): string {
    return "woof" + "!".repeat(volume);
  }
}
const d: Trained = { kind: "dog", name: "rex", owner: "ann", tricks: ["sit"] };
const dog = new Dog("fido");
console.log(d.kind, d.name, d.owner, d.tricks[0], d.speak?.(2));
console.log(dog.name, dog.speak(3));
