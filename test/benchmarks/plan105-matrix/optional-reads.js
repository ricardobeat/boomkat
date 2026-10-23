function optional(object) { return object.optional; }
var total = 0;
for (var depth = 0; depth <= 4; depth++) {
    var object = Object.create(null);
    for (var j = 0; j < depth; j++) object = Object.create(object);
    for (var i = 0; i < 1000000; i++) if (optional(object) === undefined) total++;
}
if (total !== 5000000) throw new Error('optional reads');
print('PASS ' + total);
