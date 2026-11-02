// Enums are runtime constructs: the engine compiles them into the object
// TypeScript emits, with the numeric members mapped back to their names.
enum Color {
  Red,
  Green,
  Blue,
}
console.log(Color.Red, Color.Green, Color.Blue);
console.log(Color[Color.Red], Color[Color.Blue]);

enum Flags {
  None = 0,
  Read = 1 << 0,
  Write = 1 << 1,
  All = Read | Write,
}
console.log(Flags.Read, Flags.Write, Flags.All);
console.log(Flags[Flags.All]);

enum Mixed {
  First = 1,
  Second = "two",
  Third = 3,
}
console.log(Mixed.First, Mixed.Second, Mixed.Third);
console.log(Mixed[Mixed.First], Mixed["two"]);

enum Counted {
  One = 5,
  Two,
  Three,
}
console.log(Counted.One, Counted.Two, Counted.Three);

const enum Flags2 {
  A = 10,
  B = 20,
}
console.log(Flags2.A, Flags2.B);

// An initialiser that is not a constant runs as written, and a member it
// names stands for that member's value.
enum Derived { A = "a", B = A + "b", C = `${B}c`, D = A }
console.log(JSON.stringify(Derived));
enum Computed { A = 3, B = A.toString().length, C = "xyz".length, D = B + C, E }
console.log(JSON.stringify(Computed));
enum Self { Self = 1, Next = Self + 1 }
console.log(JSON.stringify(Self));

// The bitwise operators fold through ToInt32, as they compute at runtime.
enum Bits { A = 2 ** 31, B = ~A, C = A | 0, D = 1 << 33, F = -1 >>> 0, G = NaN | 1 }
console.log(JSON.stringify(Bits));
