// Arithmetic and update operators run ToNumeric on an object operand once, take
// the BigInt path when it yields a BigInt, and leave the binding alone when the
// conversion throws.
function assert(ok, what) { if (!ok) throw new Error('FAIL: ' + what); }
var calls = 0;
var B = 2n ** 70n;
var big = () => ({ valueOf() { calls++; return B + 1n; } });
var num = { valueOf() { calls++; return 3; } };
var five = Object(5n);

assert(big() - big() === 0n && big() * five === (B + 1n) * 5n && big() / five === (B + 1n) / 5n, '- * / on BigInt results');
assert(big() % five === (B + 1n) % 5n && five ** five === 3125n && five * five === 25n, '% ** on BigInt results');
assert(num * num === 9 && num - num === 0 && num / num === 1 && num % num === 0 && num ** num === 27, 'Number results');
assert(calls === 15, 'each operand converted once: ' + calls);
var mixed = 0;
for (var op of [(a, b) => a - b, (a, b) => a * b, (a, b) => a / b, (a, b) => a % b, (a, b) => a ** b]) {
    try { op(big(), num); } catch (e) { mixed += e instanceof TypeError; }
}
assert(mixed === 5, 'a BigInt and a Number do not mix');

var g = big(), h = big();
g++; --h;
assert(g === B + 2n && h === B, 'global ++ and --');
(function () {
    var x = big(), y = big(), z = big(), o = { p: big() }, a = [big()];
    let l = big();
    assert(x++ === B + 1n && x === B + 2n && --y === B, 'local ++ and --');
    { l++; }
    (() => z--)();
    assert(l === B + 2n && z === B && ++o.p === B + 2n && a[0]-- === B + 1n && a[0] === B, 'let, captured, member');
    var w = { v: big() };
    with (w) { v++; }
    assert(w.v === B + 2n, 'with');
    var s = '4', u, t = 'a';
    s++; u--; t++;
    assert(s === 5 && u !== u && t !== t, 'string and undefined operands');
})();

var bad = { valueOf() { throw new Error('no'); } }, sym = Symbol('s');
var kept = 0, gb = bad, gs = sym;
try { gb++; } catch (e) { kept += gb === bad; }
try { --gs; } catch (e) { kept += gs === sym; }
(function () {
    var x = bad, y = sym, c = bad, o = { p: bad };
    try { x++; } catch (e) { kept += x === bad; }
    try { --y; } catch (e) { kept += y === sym; }
    try { (() => c++)(); } catch (e) { kept += c === bad; }
    try { o.p--; } catch (e) { kept += o.p === bad; }
    try { x * x; } catch (e) { kept += e.message === 'no'; }
})();
assert(kept === 7, 'a throwing conversion leaves the binding alone: ' + kept);
print('object operands to numeric: OK');
