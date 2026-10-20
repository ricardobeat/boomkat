var N = 20000;
var text = 'The quick brown fox jumps over the lazy dog. The fox is quick and brown. End.';
var email = 'user@example.com';
var checksum = 0;
var started;
var match;

var literal = /fox/;
started = Date.now();
for (var i = 0; i < N; i++) {
    match = literal.exec(text);
    if (match !== null && match[0] === 'fox' && match.index === 16) checksum++;
}
print('PHASE exec_literal ' + (Date.now() - started));

var groups = /(\w+)@(\w+\.\w+)/;
started = Date.now();
for (var j = 0; j < N; j++) {
    match = groups.exec(email);
    if (match !== null && match[1] === 'user' && match[2] === 'example.com') checksum++;
}
print('PHASE exec_captures ' + (Date.now() - started));

var unmatched = /(missing)?fox/;
started = Date.now();
for (var k = 0; k < N; k++) {
    match = unmatched.exec(text);
    if (match !== null && match[1] === undefined && 1 in match) checksum++;
}
print('PHASE exec_unmatched_capture ' + (Date.now() - started));

var global = /fox/g;
started = Date.now();
for (var m = 0; m < N; m++) {
    global.lastIndex = 0;
    var first = global.exec(text);
    var second = global.exec(text);
    if (first !== null && second !== null && first.index === 16 && second.index === 49) checksum++;
}
print('PHASE exec_global_pair ' + (Date.now() - started));
print('CHECK ' + checksum);
