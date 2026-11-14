var N = 2000000; var s = 0;
var re = /b(a)r/; var str = 'foo bar baz';
function f(i) { return str.replace(re, '[$1]'); }
for (var i = 0; i < N; i++) s += f(i).length;
print(s);
