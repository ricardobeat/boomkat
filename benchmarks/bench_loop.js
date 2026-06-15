// Bench 1: Tight arithmetic loop — raw VM dispatch speed
var sum = 0;
for (var i = 0; i < 100000; i++) {
    sum += i * 3 + i - i / 2;
    sum = sum | 0;
}
