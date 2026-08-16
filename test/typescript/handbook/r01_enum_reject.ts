// Enums are runtime constructs, not erasable syntax: the compiler must
// reject them in ts_mode (tsc rejects them under --erasableSyntaxOnly with
// TS1294; node's type stripping refuses them as TS1289).
enum Color {
  Red,
  Green,
  Blue,
}
console.log(Color.Red);
