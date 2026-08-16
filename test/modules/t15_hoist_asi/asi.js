// Statements terminated by ASI (no semicolon) immediately before function
// declarations. The compiler's top-level pre-scan classifies a `function`
// keyword by the token that precedes it: with the previous statement ended
// only by a line break, the pre-scan used to treat the declaration as an
// expression, skip it, and never record its name, so the export clause
// below failed to link (`export { f }` named no runtime binding). The
// exported names must resolve and the values must be the ASI'd constants.

const base = 1
function f() { return base + 4 }

let seed = 10
function g() { return seed + 2 }

const threshold = 5
async function h() { return threshold + 1 }

export { f, g, h }
