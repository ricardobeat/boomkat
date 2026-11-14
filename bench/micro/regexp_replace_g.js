var N = 2000000; var s = 0;
var re = /o/g; var str = 'foo bar boz';
function f(i) { return str.replace(re, '0'); }
for (var i = 0; i < N; i++) s += f(i).length;
print(s);
