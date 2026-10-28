var proto = {length: 99};
var one = Object.create(proto);
var two = Object.create(proto); two.b = 2;
var arr = [1, 2, 3]; Object.setPrototypeOf(arr, proto);
function lengthOf(x) { return x.length + 0; }
for (var i = 0; i < 500; i++) { lengthOf(one); lengthOf(two); }
print('ordinary=' + lengthOf(one) + ',' + lengthOf(two) + ' array=' + lengthOf(arr));
