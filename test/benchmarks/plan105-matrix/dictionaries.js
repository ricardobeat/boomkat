function make(seed, count) {
    var object = {};
    for (var j = 0; j < count; j++) object['key_' + seed + '_' + j] = j;
    return object;
}
var sizes = [16,32,64,128];
var sum = 0;
for (var s = 0; s < sizes.length; s++) {
    var retained = [];
    for (var i = 0; i < 1200; i++) retained.push(make(i, sizes[s]));
    for (var i = 0; i < retained.length; i++) {
        for (var round = 0; round < 4; round++) {
            sum += retained[i]['key_' + i + '_' + (sizes[s]-1)];
        }
    }
}
if (sum !== 1132800) throw new Error('dictionary result ' + sum);
print('PASS ' + sum);
