// Array/matrix allocation only
var matrix = [];
for (var i = 0; i < 200; i++) {
    var row = [];
    for (var j = 0; j < 200; j++) {
        row.push((i + j) % 256);
    }
    matrix.push(row);
}
var sum = 0;
for (var i = 0; i < matrix.length; i++) {
    for (var j = 0; j < matrix[i].length; j++) {
        sum += matrix[i][j];
    }
}
if (sum < 0) print("never");
