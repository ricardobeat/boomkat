function append(a, v) { return a.push(v) + 0; }
for (var i = 0; i < 500; i++) { var a = [1, 2, 3]; a.pop(); append(a, i); }
var a = [1, 2, 3]; a.pop();
print('length=' + append(a, undefined) + ' own=' + Object.prototype.hasOwnProperty.call(a, '2') + ' in=' + (2 in a) + ' keys=' + Object.keys(a).length);
var visits = 0; a.forEach(function () { visits++; }); print('visits=' + visits);
