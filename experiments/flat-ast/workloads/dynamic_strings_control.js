function kernel(prefix, label, enabled, count) { return prefix + (label + enabled + ":" + count); }
var total = 0;
for (var i = 0; i < 400000; i++) total += kernel("p" + (i & 7), "mode:", true, 8).length;
if (total !== 5200000) throw new Error("checksum: " + total);
print(total);
