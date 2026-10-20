var calls = 0;
var value = { valueOf: function () { calls++; return 7; } };
function repeated(a, b) {
    const first = a * b;
    const second = a * b;
    return first + second;
}
var sum = 0;
for (var i = 0; i < 200000; i++) sum += repeated(value, 3);
print(sum + ':' + calls);
