function Record(value) { this.value = value; this.other = 0; }
function literal(value) { return {value:value, other:0}; }
function read(object) { return object.value; }
var objects = [];
for (var i = 0; i < 1024; i++) objects.push(i % 2 ? new Record(i) : literal(i));
var sum = 0;
for (var i = 0; i < 5000000; i++) sum += read(objects[i & 1023]);
var cycles = Math.floor(5000000 / 1024), remainder = 5000000 % 1024;
var expected = cycles * 1023 * 1024 / 2 + remainder * (remainder - 1) / 2;
if (sum !== expected) throw new Error('mixed construction');
print('PASS ' + sum);
