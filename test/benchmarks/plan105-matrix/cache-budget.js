var functions = [];
for (var i = 0; i < 1200; i++) functions.push(eval('(function(o){ return o.x + '+i+'; })'));
var sum = 0, object = {x:3};
for (var round = 0; round < 2; round++) {
    for (var i = 0; i < functions.length; i++) sum += functions[i](object);
}
if (sum !== 1446000) throw new Error('budget fallback ' + sum);
print('PASS ' + sum);
