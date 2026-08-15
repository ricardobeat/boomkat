// The destructuring-assignment lookahead skips a leading `{`/`[` to see whether
// a `=` follows. That scan walks raw tokens, so a `}` closing a `${...}`
// substitution must be classified with TemplateScan rather than counted as
// pattern nesting: miscounting it consumes a real `}` to compensate and runs the
// scan far past the pattern, resuming the re-lex inside a later string literal
// (mathjs failed to parse with "unexpected character" thousands of bytes away).

function check(label, got, want) {
    if (got !== want) {
        print("FAIL " + label + ": got " + got + ", want " + want);
    }
}

var x = 1;

// Object literal in expression position whose member body holds a template.
const a = { m: function () { return `v${x}w`; }, n: 2 };
check("object with template method", a.m() + a.n, "v1w2");

// The same shape as a call argument.
function take(o) { return o.n; }
check("call argument", take({ m: function () { return `v${x}w`; }, n: 5 }), 5);

// Array literal in expression position.
const b = [function () { return `a${x}b`; }, 3];
check("array with template", b[0]() + b[1], "a1b3");

// Nested substitutions, and braces inside a substitution expression.
const c = { k: function () { return `${`in${x}`}${(() => { return x; })()}`; } };
check("nested substitution", c.k(), "in11");

// A real destructuring assignment still parses after the same shapes.
let p, q;
({ p, q } = { p: 8, q: 9 });
check("destructuring assignment", p + q, 17);

let r, s;
[r, s] = [4, 6];
check("array destructuring", r + s, 10);

// Destructuring whose default value contains a template.
let t;
({ t = `d${x}` } = {});
check("default with template", t, "d1");

print("destructure_lookahead_template: done");
