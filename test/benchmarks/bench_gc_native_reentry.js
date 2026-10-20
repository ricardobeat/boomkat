// Native iteration callbacks publish suspended VM frames during marking.
var anchors = [];
for (var i = 0; i < 20000; i++) anchors.push({ index: i });
var total = 0;
for (var round = 0; round < 200; round++) {
    var values = Array.from({ length: 256 }, function (_, index) {
        return { value: index, owner: anchors[(round * 256 + index) % anchors.length] };
    });
    total += values.reduce(function (sum, value) {
        if (value.owner.index < 0) throw new Error("lost callback root");
        return sum + value.value;
    }, 0);
}
if (total !== 6528000) throw new Error("native callback result corrupted");
print("native reentry passed " + total);
