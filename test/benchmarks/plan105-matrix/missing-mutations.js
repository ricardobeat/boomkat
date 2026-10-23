function read(object) { return object.optional; }
function check(a,b,va,vb) {
    for (var i = 0; i < 1000; i++) {
        if (read(a) !== va || read(b) !== vb) throw new Error('stale missing cache');
    }
}
var root = Object.create(null);
var p = Object.create(root);
var a = Object.create(p);
var b = Object.create({optional:2});
check(a,b,undefined,2);
root.optional = 3;
check(a,b,3,2);
delete root.optional;
check(a,b,undefined,2);
Object.defineProperty(p,'optional',{get:function(){return 4;},configurable:true});
check(a,b,4,2);
delete p.optional;
check(a,b,undefined,2);
a.optional = undefined;
check(a,b,undefined,2);
if (!Object.prototype.hasOwnProperty.call(a,'optional')) throw new Error('own undefined');
delete a.optional;
Object.setPrototypeOf(a,{optional:5});
check(a,b,5,2);
Object.setPrototypeOf(a,p);
check(a,b,undefined,2);
var proxy = new Proxy({}, {get:function(t,k){return k === 'optional' ? 6 : t[k];}});
check(a,proxy,undefined,6);
for (var i = 0; i < 100; i++) p['key'+i] = i;
check(a,b,undefined,2);
p.optional = 7;
check(a,b,7,2);
print('PASS');
