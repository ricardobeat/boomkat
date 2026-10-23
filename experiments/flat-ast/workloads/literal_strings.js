function kernel(prefix) { return prefix + ("mode:" + true + ":" + (1 << 3)); }
var total = 0;
for (var i = 0; i < 400000; i++) total += kernel("p" + (i & 7)).length;
if (total !== 5200000) throw new Error("checksum: " + total);
print(total);
