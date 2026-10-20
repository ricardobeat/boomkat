// Object allocation only
var n = 5000;
var objects = [];
for (var i = 0; i < n; i++) {
    objects.push({id: i, name: "obj_" + (i % 100), flag: (i % 2) == 0, nested: {x: i * 1.5, y: i / 3, tag: String(i)}});
}
var sum = 0;
for (var i = 0; i < objects.length; i++) { sum += objects[i].id; sum += objects[i].nested.x | 0; }
if (sum < 0) print("never");
