var N = 2000000; var s = 0;
var re = /\d+/g; var str = 'a1 b22 c333 d4';
function f(i) { return str.match(re); }
for (var i = 0; i < N; i++) s += f(i).length;
print(s);
