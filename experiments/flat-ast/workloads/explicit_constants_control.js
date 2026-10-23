function kernel(x) { return (x & 9) + 5; }
var total = 0;
for (var i = 0; i < 1000000; i++) total += kernel(i & 255);
if (total !== 9500000) throw new Error("checksum: " + total);
print(total);
