var N = 20000;
var text = 'The quick brown fox jumps over the lazy dog. The fox is quick and brown. End.';
var email = 'user@example.com, admin@test.org, support@company.co.uk';
var checksum = 0;
var started;

var literal = /fox/;
started = Date.now();
for (var i = 0; i < N; i++) {
    if (literal.test(text)) checksum++;
}
print('PHASE test_literal_match ' + (Date.now() - started));

var groups = /(\w+)@(\w+\.\w+)/;
started = Date.now();
for (var j = 0; j < N; j++) {
    if (groups.test(email)) checksum++;
}
print('PHASE test_groups_match ' + (Date.now() - started));

var missing = /missing/;
started = Date.now();
for (var k = 0; k < N; k++) {
    if (missing.test(text)) checksum++;
}
print('PHASE test_literal_miss ' + (Date.now() - started));

var global = /fox/g;
started = Date.now();
for (var m = 0; m < N; m++) {
    global.lastIndex = 0;
    if (global.test(text)) checksum++;
}
print('PHASE test_global_match ' + (Date.now() - started));

var sticky = /fox/y;
var foxIndex = text.indexOf('fox');
started = Date.now();
for (var n = 0; n < N; n++) {
    sticky.lastIndex = foxIndex;
    if (sticky.test(text)) checksum++;
}
print('PHASE test_sticky_match ' + (Date.now() - started));

started = Date.now();
for (var p = 0; p < N; p++) {
    var matchLiteral = literal.exec(text);
    if (matchLiteral !== null && matchLiteral.index === 16) checksum++;
}
print('PHASE exec_literal_control ' + (Date.now() - started));

started = Date.now();
for (var q = 0; q < N; q++) {
    var matchGroups = groups.exec(email);
    if (matchGroups !== null && matchGroups[1] === 'user' && matchGroups[2] === 'example.com') checksum++;
}
print('PHASE exec_groups_control ' + (Date.now() - started));

print('CHECK ' + checksum);
