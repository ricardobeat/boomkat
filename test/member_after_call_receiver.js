// A member access after a call (`f().x`) leaves a pending call receiver.
// It must be released with the chain's value, or a later member call frees
// its stale register and the method key overwrites the object it reads.
var X = { Y: { m: function () { return { l: 5 }; } } };

function lexical() {
    let d = X.Y.m().l;
    let r = d;
    let s = X.Y.m(r);
    return s.l;
}
if (lexical() !== 5) throw new Error("lexical: " + lexical());

function constArray() {
    const d = X.Y.m().l;
    const n = 1;
    const r = [d, n];
    const s = X.Y.m(r);
    return s.l;
}
if (constArray() !== 5) throw new Error("const array");

const top = X.Y.m().l;
const copy = top;
const res = X.Y.m(copy);
if (res.l !== 5) throw new Error("top level");

// The same shape with a computed key and a longer chain after the call.
var Z = { a: { b: function () { return { c: { d: 7 } }; } } };
function computed() {
    let v = Z.a["b"]().c.d;
    let w = v;
    let u = Z.a.b(w).c;
    return u.d;
}
if (computed() !== 7) throw new Error("computed");
console.log("ok");
