function readOwn(o) { return o.value; }
function readThis() { return this.value; }
var first = {value: 3, read: readThis};
var second = {pad: 19, value: 7, read: readThis};
var third = {pad: 23, other: 29, value: 11, read: readThis};
var objects = [first, second, third];
for (var i = 0; i < 3000; i++) {
    var o = objects[i % 3];
    if (readOwn(o) !== o.value || o.read() !== o.value) throw Error("polymorphic own read");
}
var getterCalls = 0;
Object.defineProperty(second, "value", {get: function () { getterCalls++; return 17; }});
for (var j = 0; j < 100; j++) {
    if (readOwn(second) !== 17 || second.read() !== 17) throw Error("accessor transition");
}
if (getterCalls !== 200) throw Error("getter count");
print("polymorphic own reads ok");
