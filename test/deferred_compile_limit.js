// A deferred body over a compiler limit throws a catchable SyntaxError from
// each way of entering it, and the script carries on.
var body = '';
for (var i = 0; i < 70000; i++) body += 'var v' + i + '=' + i + ';';
var got = (0, eval)(`
    function big() {${body}}
    var o = Object.defineProperty({}, 'g', { get: big, set: big });
    class D extends big { constructor() { super(); } }
    var ways = [() => big(), () => new big(), () => o.g, () => { o.g = 1; }, () => new D(),
        () => [1].map(big), () => big.call(null), () => Reflect.construct(big, [])];
    ways.map(way => { try { way(); return 'no throw'; } catch (e) { return e.name + ': ' + e.message; } });
`);
for (var i = 0; i < got.length; i++) {
    if (got[i] !== 'SyntaxError: register limit exceeded') throw new Error('way ' + i + ': ' + got[i]);
}
print('deferred compile limit: OK');
