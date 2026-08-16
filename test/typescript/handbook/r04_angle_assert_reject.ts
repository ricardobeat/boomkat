// Angle-bracket type assertions (`<string>x`) are excluded from the
// erasable corpus: tsc rejects them under --erasableSyntaxOnly (TS1294) and
// node's type stripping does not support them, so both oracles agree this
// is out of scope.
const raw: any = "text";
const len = (<string>raw).length;
console.log(len);
