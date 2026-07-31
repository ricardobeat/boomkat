// Verbatim from https://rosettacode.org/wiki/Function_composition (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function compose(f, g) {
  return function(x) {
    return f(g(x));
  };
}
