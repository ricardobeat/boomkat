var N = 2000000; var s = 0;
var re = /b[aeiou]z/; var str = 'foo bar baz';
function f(i) { return str.search(re); }
for (var i = 0; i < N; i++) s += f(i);
print(s);
