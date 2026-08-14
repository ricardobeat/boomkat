var Immutable = module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

var list = Immutable.List([1, 2, 3]);
rec("list_push", list.push(4).toJS());
rec("list_immutable", list.toJS());

var map1 = Immutable.Map({ a: 1, b: 2 });
rec("map_set", map1.set("c", 3).toJS());
rec("map_get", map1.get("a"));

var map2 = Immutable.Map({ a: 1 });
var map3 = Immutable.Map({ a: 1 });
rec("structural_equal", Immutable.is(map2, map3));

var set1 = Immutable.Set([1, 2, 2, 3]);
rec("set_size", set1.size);

console.log(lines.join("\n"));
console.log(lines.length + " immutable API checks recorded, 0 threw");
