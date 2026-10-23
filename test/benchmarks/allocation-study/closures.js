var closures = [];
function make(value) {
    return function retainedValue() { return value; };
}
for (var i = 0; i < 150000; i++) closures.push(make(i));
var total = 0;
for (var i = 0; i < closures.length; i++) total += closures[i]();
if (total !== 11249925000) throw new Error('closure sum: ' + total);
print('PASS ' + total);
