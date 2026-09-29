var N = 20000;
var text = 'The quick brown fox jumps over the lazy dog. The fox is quick and brown. End.';
var checksum = 0;
var started;

var literal = /fox/;
started = Date.now();
for (var i = 0; i < N; i++) {
    var literalMatch = literal.exec(text);
    if (literalMatch !== null && literalMatch.index === 16) checksum++;
}
print('PHASE exec_non_global ' + (Date.now() - started));

var global = /\w+/g;
started = Date.now();
for (var j = 0; j < 2000; j++) {
    global.lastIndex = 0;
    var globalMatches = 0;
    while (global.exec(text) !== null) globalMatches++;
    if (globalMatches === 16) checksum++;
}
print('PHASE exec_global_scan ' + (Date.now() - started));

var stickyMiss = /zz/y;
started = Date.now();
for (var k = 0; k < N; k++) {
    stickyMiss.lastIndex = k % text.length;
    if (stickyMiss.exec(text) === null) checksum++;
}
print('PHASE exec_sticky_miss ' + (Date.now() - started));

started = Date.now();
for (var m = 0; m < 2000; m++) {
    var pieces = text.split(/\s+/);
    if (pieces.length === 16) checksum++;
}
print('PHASE split_regexp ' + (Date.now() - started));
print('CHECK ' + checksum);
