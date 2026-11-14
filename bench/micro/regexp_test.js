var N = 2000000; var s = 0;
var re = /b[aeiou]z/; var str = 'foo bar baz';
function f(i) { return re.test(str); }
for (var i = 0; i < N; i++) if (f(i)) s++;
print(s);
