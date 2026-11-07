// Patterns that can match the empty string only at the start (`^`) or end
// (`$`) of the input skip the positions in between. The result must equal a
// search done by trying a sticky copy of the pattern at every position.
var pats = ['^\\s*|\\s*$', '^\\s+|\\s+$', '^a*', 'a*$', '^|b', 'b|$', 'x*$', '(?:^|b)',
            '\\s*$', '^\\s*', '$', '^', '^a|$', '^a*|b*$', '(^)|(x$)'];
var flagsets = ['', 'u'];
var inputs = ['', '  x  ', 'x', '   ', 'a', 'aab', 'bab', 'xx\n', '\n a', '\u{1F600} ', 'ሴ  ', 'b', 'abxb'];
function naive(src, flags, s, from) {
    var y = new RegExp(src, flags + 'y');
    for (var i = from; i <= s.length; i++) {
        y.lastIndex = i;
        var m = y.exec(s);
        if (m) return m;
    }
    return null;
}
for (var p = 0; p < pats.length; p++) for (var f = 0; f < flagsets.length; f++) for (var k = 0; k < inputs.length; k++) {
    var g = new RegExp(pats[p], flagsets[f] + 'g'), s = inputs[k];
    for (var from = 0; from <= s.length; from++) {
        g.lastIndex = from;
        var a = g.exec(s), b = naive(pats[p], flagsets[f], s, from);
        var sa = a && a.index + ':' + a[0] + ':' + a.length, sb = b && b.index + ':' + b[0] + ':' + b.length;
        if (sa !== sb) throw new Error('FAIL /' + pats[p] + '/' + flagsets[f] + ' on ' + JSON.stringify(s) + ' from ' + from + ': ' + sa + ' vs ' + sb);
    }
}
if ('  x  '.replace(/^\s*|\s*$/g, '') !== 'x') throw new Error('FAIL trim');
if ('  '.replace(/^\s*|\s*$/g, '-') !== '--') throw new Error('FAIL trim all space');
print('ok');
