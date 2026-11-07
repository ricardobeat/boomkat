// Deferred bodies share source coordinates after the original AST is released.
function checkLine(fn, line, column) {
    var frame = fn().stack.split('\n')[1];
    var suffix = ':' + line + ':' + column + ')';
    if (frame.slice(-suffix.length) !== suffix)
        throw new Error('Expected ' + suffix + ', got ' + frame);
}

// Include every JS line terminator, a multibyte string, and lines beyond the
// deferred function's source slice. Materialize nested bodies independently.
var functions = (0, eval)(
    '// prefix\r\n' +
    '[function() {\r' +
    ' return function() {\u2028' +
    '  var s = "é"; return new Error(s);\u2029' +
    ' };\n' +
    '}, function() {\r\n' +
    ' return new Error("sibling");\n' +
    '}]\n// trailing source\n'
);
checkLine(functions[1], 7, 9);
var nested = functions[0]();
functions = null;
for (var i = 0; i < 30; i++) (0, eval)('(function() { return 1; })')();
checkLine(nested, 4, 24);
checkLine(nested, 4, 24);

// A single-line table must also be reusable (and preserve byte columns).
checkLine((0, eval)('(function() { return new Error("one"); })'), 1, 22);
print('deferred source lines: OK');
