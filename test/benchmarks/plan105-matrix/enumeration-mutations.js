var symbol = Symbol('key'), calls = 0;
function make() {
    var o = {z:1,a:2};
    Object.defineProperty(o,'getter',{get:function(){calls++;return 3;},enumerable:true,configurable:true});
    Object.defineProperty(o,'hidden',{value:4,enumerable:false,configurable:true});
    o[symbol] = 5;
    return o;
}
function check(object) {
    var keys = Object.keys(object), names = Object.getOwnPropertyNames(object), all = Reflect.ownKeys(object);
    if (keys.join(',') !== 'z,a,getter' || names.join(',') !== 'z,a,getter,hidden'
        || all.length !== 5 || all[4] !== symbol || Object.getOwnPropertySymbols(object)[0] !== symbol)
        throw new Error('key plan order');
    keys[0]='changed';
    if (Object.keys(object)[0] !== 'z') throw new Error('fresh key result');
}
var a = make(), b = make();
for (var i = 0; i < 2000; i++) { check(a); check(b); }
if (calls !== 0) throw new Error('enumeration invoked getter');
Object.defineProperty(a,'a',{enumerable:false});
if (Object.keys(a).join(',') !== 'z,getter' || Object.keys(b).join(',') !== 'z,a,getter') throw new Error('shared descriptors');
delete a.z; a.z=9;
if (Object.keys(a).join(',') !== 'getter,z') throw new Error('delete/readd order');
var indexed = {'10':1,'2':2,z:3};
if (Reflect.ownKeys(indexed).join(',') !== '2,10,z') throw new Error('integer order');
var proxy = new Proxy({x:1},{ownKeys:function(){return ['x'];}});
if (Object.keys(proxy)[0] !== 'x') throw new Error('proxy own keys');
print('PASS');
