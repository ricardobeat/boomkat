// Bench 5: Array operations — push, index, length
var arr = [];
for (var i = 0; i < 10000; i++) {
    arr.push(i);
}
var sum = 0;
for (var i = 0; i < arr.length; i++) {
    sum += arr[i];
}
