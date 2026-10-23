function assert(value) { if (!value) throw new Error('integrity semantics'); }
var key = Symbol('key');
var o = {a:1,b:2,c:3,d:4,e:5,f:6};
var peer = {a:1,b:2,c:3,d:4,e:5,f:6};
Object.defineProperty(o,'getter',{get:function(){return this.a;},configurable:true});
o[key] = 7;
Object.freeze(o);
assert(Object.isFrozen(o) && Reflect.ownKeys(o).length === 8);
assert(o.getter === 1 && o[key] === 7);
assert(!Object.getOwnPropertyDescriptor(o,'getter').configurable);
assert(!Object.getOwnPropertyDescriptor(o,key).writable);
peer.a = 9;
assert(peer.a === 9 && Object.isExtensible(peer));
var strictFailed = false;
try { (function(){'use strict'; o.a = 10;})(); } catch (e) { strictFailed = e instanceof TypeError; }
assert(strictFailed && o.a === 1);
var a = [1,,3];
a.named = 4;
Object.seal(a);
assert(Object.isSealed(a) && !Object.isFrozen(a));
a[0] = 8;
assert(a[0] === 8 && !(1 in a));
Object.freeze(a);
assert(Object.isFrozen(a) && !Object.getOwnPropertyDescriptor(a,'length').writable);
assert(!Object.getOwnPropertyDescriptor(a,'0').writable);
function mapped(value) {
    Object.freeze(arguments);
    value = 99;
    assert(arguments[0] === 3 && Object.isFrozen(arguments));
}
mapped(3);
var empty = {};
Object.freeze(empty);
assert(Object.isFrozen(empty));
var sealed = {a:1,b:2,c:3,d:4,e:5,f:6};
Object.seal(sealed);
Object.defineProperty(sealed,'a',{value:4});
assert(sealed.a === 4 && Object.isSealed(sealed));
print('PASS');
