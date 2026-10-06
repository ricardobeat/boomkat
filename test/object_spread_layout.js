function equal(actual, expected) {
    if (actual !== expected) throw new Error(actual + " !== " + expected);
}
function copy(source) { return {...source}; }
const object = {id: 9};
const source = {a: "value", b: object, c: undefined, d: 4, e: 5, f: 6};
for (var i = 0; i < 100; i++) {
    const result = copy(source);
    equal(result.a, "value"); equal(result.b, object);
    equal(Object.keys(result).join(","), "a,b,c,d,e,f");
    const descriptor = Object.getOwnPropertyDescriptor(result, "c");
    equal(descriptor.enumerable && descriptor.writable && descriptor.configurable, true);
    result.a = "changed";
    equal(source.a, "value");
}
const symbol = Symbol("key");
source[symbol] = object;
equal(copy(source)[symbol], object);
const numeric = {2: "two", 0: "zero", x: 1};
equal(Object.keys(copy(numeric)).join(","), "0,2,x");
const inherited = copy(numeric);
const array = [];
array.length = 1;
Object.setPrototypeOf(array, inherited);
equal(Array.prototype.pop.call(array), "zero");
const protoKey = { ["__proto__"]: object };
const protoCopy = copy(protoKey);
equal(Object.getPrototypeOf(protoCopy), Object.prototype);
equal(Object.getOwnPropertyDescriptor(protoCopy, "__proto__").value, object);

const hidden = {a: 1};
Object.defineProperty(hidden, "b", {value: 2});
equal(Object.keys(copy(hidden)).join(","), "a");
Object.freeze(hidden);
equal(Object.getOwnPropertyDescriptor(copy(hidden), "a").writable, true);
const first = {a: 1}, second = {a: 2, b: 3};
const merged = {...first, ...second, a: 4};
equal(merged.a, 4); equal(merged.b, 3);

var order = [];
const getters = {get a() { order.push("a"); delete this.b; return 1; }, b: 2};
equal(Object.keys(copy(getters)).join(","), "a");
equal(order.join(","), "a");
const proxy = new Proxy({a: 1}, {
    ownKeys: function () { order.push("keys"); return ["a"]; },
    getOwnPropertyDescriptor: function () {
        order.push("descriptor");
        return {enumerable: true, configurable: true};
    },
    get: function () { order.push("get"); return 8; }
});
order.length = 0;
equal(copy(proxy).a, 8);
equal(order.join(","), "keys,descriptor,get");
equal(Object.keys({...null, ...undefined}).length, 0);
equal(Object.keys({..."ab"}).join(","), "0,1");
const retained = [];
for (var i = 0; i < 1500; i++) {
    retained.push(copy({text: "owned" + i, child: {id: i}}));
}
for (var i = 0; i < 1500; i++) {
    equal(retained[i].text, "owned" + i);
    equal(retained[i].child.id, i);
}
print("PASS object spread layout");
