function make(i) { return {value:i,other:0}; }
function read(o) { return o.value; }
var objects = [];
for (var i = 0; i < 1024; i++) objects.push(make(i));
var sum = 0;
for (var i = 0; i < 5000000; i++) sum += read(objects[i & 1023]);
var cycles = Math.floor(5000000 / 1024), remainder = 5000000 % 1024;
var expected = cycles * 1023 * 1024 / 2 + remainder * (remainder - 1) / 2;
if (sum !== expected) throw new Error('shape order');
print('PASS ' + sum);
