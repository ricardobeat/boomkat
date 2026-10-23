function kernel(x) { const scale = 2; const offset = scale + 3; const mask = (offset << 1) - 1; return (x & mask) + offset; }
var total = 0;
for (var i = 0; i < 1000000; i++) total += kernel(i & 255);
if (total !== 9500000) throw new Error("checksum: " + total);
print(total);
