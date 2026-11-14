var N = 2000000; var s = 0;
function f(i) { return i; }
for (var i = 0; i < N; i++) s += f(i) & 1;
print(s);
