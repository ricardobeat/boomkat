function makeLoopBinding(value) {
    eval('');
    return function (n) {
        for (var i = 0; i < 3; i++) n += value;
        return n;
    };
}
var a = { run: makeLoopBinding(2) }, b = { run: makeLoopBinding(7) };
for (var i = 0; i < 200; i++) {
    if (a.run(1) !== 7) throw new Error('first closure at ' + i);
    if (b.run(1) !== 22) throw new Error('second closure at ' + i);
}
print('closure binding PASS');
