var N = 2000000; var s = 0;
var re = /q+/g; var str = 'foo bar baz';
function f(i) { return str.replace(re, 'x'); }
for (var i = 0; i < N; i++) s += f(i).length;
print(s);
