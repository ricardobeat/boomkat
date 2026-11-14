var N = 2000000; var s = 0;
var re = /,\s*/; var str = 'a, b,c,  d, e';
function f(i) { return str.split(re); }
for (var i = 0; i < N; i++) s += f(i).length;
print(s);
