function readIndex(a, i) { return a[i]; }
var a = [3, 5, 7, 11, 13, 17, 19, 23], sum = 0;
for (var warm = 0; warm < 10000; warm++) sum += readIndex(a, warm & 7);
sum = 0;
var start = Date.now();
for (var i = 0; i < 30000000; i++) sum += readIndex(a, i & 7);
if (sum !== 367500000) throw Error('incorrect sum ' + sum);
print('array-read: ' + (Date.now() - start) + ' ms');
