// Plan 102 candidate 1: literal arithmetic inside a repeatedly called body.
function kernel(x) {
    return x + ((2 + 3) * 4 - 6 / 2) + ((11 % 4) * (7 - 2));
}
var total = 0;
for (var i = 0; i < 1000000; i++) total += kernel(i & 255);
if (total !== 159493856) throw new Error('constant kernel: ' + total);
print(total);
