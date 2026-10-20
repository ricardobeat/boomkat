var values = [1,2,3,4,5,6,7,8];
function match(value) { return value === 5; }
var sum = 0;
for (var i = 0; i < 200000; i++) {
    sum += values.find(match);
    sum += values.findLast(match);
    sum += values.findIndex(match);
    sum += values.findLastIndex(match);
}
print(sum);
