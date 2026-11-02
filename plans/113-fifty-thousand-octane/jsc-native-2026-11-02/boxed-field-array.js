// Representative boxed own-field and indexed Array dispatch; not an original benchmark body.
function fieldArrayDispatch(rows, count) {
    var sum = 0;
    for (var i = 0; i < count; i++) {
        var row = rows[i & 255];
        sum += row.value * row.scale;
    }
    return sum;
}
var rows = [];
for (var i = 0; i < 256; i++) rows.push({value: i + 0.25, scale: (i & 7) + 0.5});
var checksum = 0;
for (var warm = 0; warm < 128; warm++) checksum += fieldArrayDispatch(rows, 4096);
if (checksum !== 270663680) throw new Error('unexpected checksum ' + checksum);
print('Field-array capture checksum ' + checksum);
