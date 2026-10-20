function count(n) {
    var i = 0.5;
    while (i < n) i++;
    return i;
}
var result = count(5000000);
if (result !== 5000000.5) throw new Error('wrong count');
print(result);
