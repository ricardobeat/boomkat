function readAlias(o) { var p = o; return p.a + p.b; }
for (var i = 0; i < 300; i++) {
    var result = readAlias({a: 1, b: 2});
    if (result !== 3) { print('FAIL iteration=' + i + ' actual=' + result + ' expected=3'); break; }
}
if (i === 300) print('PASS');
