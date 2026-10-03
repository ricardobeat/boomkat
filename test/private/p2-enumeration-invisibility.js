// P2 (+ enumeration filtering): private fields must be completely
// invisible to every form of property enumeration/introspection.
class A {
    #x = 1;
    y = 2;
}

var a = new A();

var keys = Object.keys(a);
if (keys.length !== 1 || keys[0] !== "y") throw new Error("Object.keys leaked a private key: " + JSON.stringify(keys));

var names = Object.getOwnPropertyNames(a);
if (names.length !== 1 || names[0] !== "y") throw new Error("getOwnPropertyNames leaked a private key: " + JSON.stringify(names));

var syms = Object.getOwnPropertySymbols(a);
if (syms.length !== 0) throw new Error("getOwnPropertySymbols leaked a private key: " + JSON.stringify(syms));

var ownKeys = Reflect.ownKeys(a);
if (ownKeys.length !== 1 || ownKeys[0] !== "y") throw new Error("Reflect.ownKeys leaked a private key: " + JSON.stringify(ownKeys));

var json = JSON.stringify(a);
if (json !== '{"y":2}') throw new Error("JSON.stringify leaked a private key: " + json);

var forInKeys = [];
for (var k in a) forInKeys.push(k);
if (forInKeys.length !== 1 || forInKeys[0] !== "y") throw new Error("for-in leaked a private key: " + JSON.stringify(forInKeys));

var spread = { ...a };
var spreadKeys = Object.keys(spread);
if (spreadKeys.length !== 1 || spreadKeys[0] !== "y") throw new Error("spread leaked a private key: " + JSON.stringify(spreadKeys));

print("PASS");
