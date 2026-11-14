var N = 2000000; var s = 0;
var re = /(\w+)@(\w+)/; var str = 'mail bob@example now';
function f(i) { var m = re.exec(str); return m[1].length + m[2].length; }
for (var i = 0; i < N; i++) s += f(i);
print(s);
