function same(a, b) { if (a !== b) throw new Error(a + ' != ' + b); }
function capture() {
    const reads = [], writes = [];
    for (let i = 0, text = 'a'; i < 4; i++, text += 'b') {
        reads.push(() => i + ':' + text);
        writes.push(v => { i = v; });
    }
    same(reads.map(f => f()).join(','), '0:a,1:ab,2:abb,3:abbb');
    writes[1](9);
    same(reads.map(f => f()).join(','), '0:a,9:ab,2:abb,3:abbb');
}
capture();
function initialization() {
    const reads = [];
    let initial;
    for (let i = 0, init = (initial = () => i); i < 3; i++) reads.push(() => i);
    same(initial(), 0);
    same(reads.map(f => f()).join(','), '0,1,2');
}
initialization();
function abrupt() {
    const reads = [];
    outer: for (let i = 0; i < 5; i++) {
        try {
            reads.push(() => i);
            if (i === 1) continue outer;
            if (i === 3) break outer;
        } finally { reads.push(() => i); }
    }
    same(reads.map(f => f()).join(','), '0,0,1,1,2,2,3,3');
}
abrupt();
function fallback() {
    const reads = [];
    for (let i = 0; i < 3; i++) reads.push(eval('() => i'));
    same(reads.map(f => f()).join(','), '0,1,2');
    const patterns = [];
    for (let [i] = [0]; i < 3; i++) patterns.push(() => i);
    same(patterns.map(f => f()).join(','), '0,1,2');
}
fallback();
function immutable() {
    for (const i = 1;;) {
        same((() => i)(), 1);
        let threw = false;
        try { i = 2; } catch (e) { threw = e instanceof TypeError; }
        same(threw, true);
        break;
    }
}
immutable();
// Surviving closures keep string values alive through later allocations.
for (var round = 0; round < 200; round++) capture();
function stable() {
    const reads = [];
    for (let i = 0; i < 20; i++) {
        if (i === 4) continue;
        reads.push(() => i);
        if (i === 8) break;
    }
    same(reads.map(f => f()).join(','), '0,1,2,3,5,6,7,8');
}
stable();
function mutable() {
    const reads = [], writes = [];
    for (let i = 0; i < 4; i++) {
        reads.push(() => i);
        writes.push(v => { i = v; });
    }
    writes[1](12);
    same(reads.map(f => f()).join(','), '0,12,2,3');
}
mutable();
function bodyWrite() {
    const reads = [];
    for (let i = 0; i < 8; i++) { reads.push(() => i); i++; }
    same(reads.map(f => f()).join(','), '1,3,5,7');
}
bodyWrite();
function forwarding() {
    const reads = [];
    for (let i = 0; i < 4; i++) reads.push(() => () => i);
    same(reads.map(f => f()()).join(','), '0,1,2,3');
}
forwarding();
function valuesInCells() {
    var a = 'a', b = {}, c = 3, d = [4], e = 'e', f = 'f';
    return function () { return a + b.x + c + d[0] + e + f; };
}
same(valuesInCells()(), 'aundefined34ef');
const bound = (function(a, b) { return this.x + a + b; }).bind({x: 1}, 2);
same(bound(3), 6);
for (var round = 0; round < 500; round++) { stable(); mutable(); }
