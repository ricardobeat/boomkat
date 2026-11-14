var N = 2000000; var s = 0;
var re = /x(\d+)y/; var str = 'abcdefghijklmnop';
function f(i) { return re.exec(str); }
for (var i = 0; i < N; i++) if (f(i) === null) s++;
print(s);
