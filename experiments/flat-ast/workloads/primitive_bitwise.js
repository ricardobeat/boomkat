function kernel(x) { return x + ((true << 5) + (null ^ 3) + +"12" + (false ? 0 : 7)); }
var total = 0;
for (var i = 0; i < 1000000; i++) total += kernel(i & 255);
if (total !== 181493856) throw new Error("checksum: " + total);
print(total);
