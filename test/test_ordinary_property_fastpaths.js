function assert(value, message) { if (!value) throw Error(message); }
function setX(object, value) { object.x = value; }
function strictSetX(object, value) { 'use strict'; object.x = value; }

// One store site crosses receivers, inline/allocated storage, and descriptors.
var objects = [{x:0}, {x:1}, {x:2}];
for (var i=0; i<300; i++) setX(objects[i%3], i);
assert(objects[0].x===297 && objects[1].x===298 && objects[2].x===299, 'receiver slots');
for (var j=0; j<3; j++) {
    for (var k=0; k<12; k++) objects[j]['extra'+k]=k;
}
for (var i=0; i<300; i++) setX(objects[i%3], 'value-'+i);
assert(objects[0].x==='value-297' && objects[2].x==='value-299', 'grown storage and strings');
var seen;
Object.defineProperty(objects[1], 'x', {set: function(v) { seen=v; }, configurable:true});
setX(objects[1], 42);
assert(seen===42, 'setter after cache fill');
Object.defineProperty(objects[0], 'x', {writable:false});
setX(objects[0], 7);
assert(objects[0].x==='value-297', 'readonly sloppy');
strictSetX(objects[2], 1);
Object.freeze(objects[2]);
var threw=false;
try { strictSetX(objects[2], 2); } catch(e) { threw=e instanceof TypeError; }
assert(threw && objects[2].x===1, 'readonly strict');
var inherited=Object.create({set x(v) { seen=v; }});
setX(inherited, 81);
assert(seen===81 && !inherited.hasOwnProperty('x'), 'inherited setter');
var proxy=new Proxy({x:0}, {set: function(target,key,value) { seen=value; return true; }});
setX({x:0}, 3);
setX(proxy, 91);
assert(seen===91 && proxy.x===0, 'proxy store');
var dynamicKey='dynamic'+'Key';
var dynamicObject={};
dynamicObject[dynamicKey]='interned';
var keyConversions=0;
dynamicObject[{toString:function(){keyConversions++;return 'convertedKey';}}]=47;
assert(dynamicObject.dynamicKey==='interned' && dynamicObject.convertedKey===47
    && keyConversions===1, 'dynamic property keys');
var protoLocked={};
Object.defineProperty(protoLocked,'locked',{value:11,writable:false});
var receiverLocked=Object.create(protoLocked);
function sloppySetLocked(o) { o.locked=12; }
function strictSetLocked(o) { 'use strict'; o.locked=12; }
sloppySetLocked(receiverLocked);
assert(receiverLocked.locked===11 && !receiverLocked.hasOwnProperty('locked'), 'inherited readonly sloppy');
var lockedThrew=false;
try { strictSetLocked(receiverLocked); } catch(e) { lockedThrew=e instanceof TypeError; }
assert(lockedThrew && receiverLocked.locked===11, 'inherited readonly strict');

// A cached absent-property decision must notice prototype descriptor changes.
var addProto={};
function addFresh(o,v) { o.fresh=v; }
addFresh(Object.create(addProto),1);
var freshSetterValue;
Object.defineProperty(addProto,'fresh',{set:function(v){freshSetterValue=v;},configurable:true});
var freshSetterReceiver=Object.create(addProto);
addFresh(freshSetterReceiver,2);
assert(freshSetterValue===2 && !freshSetterReceiver.hasOwnProperty('fresh'), 'prototype setter after absent cache');

// Replacing the null terminator with a new prototype changes the result even
// when the object at the cached link keeps the same shape.
var extendableProto=Object.create(null);
function addLate(o,v) { o.late=v; }
addLate(Object.create(extendableProto),1);
var lateSetterValue;
Object.setPrototypeOf(extendableProto,{set late(v){lateSetterValue=v;}});
var lateReceiver=Object.create(extendableProto);
addLate(lateReceiver,2);
assert(lateSetterValue===2 && !lateReceiver.hasOwnProperty('late'), 'prototype chain extension after absent cache');

// Shape IDs can be reused after deletion. The heap-wide recycle epoch must
// invalidate an absent cache before a recycled ID can name a setter shape.
var recycleProto={other:1};
function addRecycled(o,v) { o.recycled=v; }
addRecycled(Object.create(recycleProto),1);
delete recycleProto.other;
var recycledSetterValue;
Object.defineProperty(recycleProto,'recycled',{set:function(v){recycledSetterValue=v;},configurable:true});
var recycledReceiver=Object.create(recycleProto);
addRecycled(recycledReceiver,3);
assert(recycledSetterValue===3 && !recycledReceiver.hasOwnProperty('recycled'), 'reused prototype shape id');

// The receiver can lose extensibility without changing its property shape.
function addToReceiver(o,v) { o.added=v; }
addToReceiver({},1);
var sealedReceiver={};
Object.preventExtensions(sealedReceiver);
addToReceiver(sealedReceiver,2);
assert(!sealedReceiver.hasOwnProperty('added'), 'non-extensible receiver after absent cache');

function setIndex(o,v) { o['0']=v; }
function mapped(x) {
    setIndex({'0':0}, 10);
    setIndex(arguments, 23);
    assert(x===23, 'mapped arguments');
}
mapped(1);

// Retained receivers acquire young references through the same cached store.
var retained=[];
for(var i=0;i<64;i++) retained.push({x:null});
for(var i=0;i<2048;i++) setX(retained[i%64], {value:'retained-'+i});
for(var i=0;i<64;i++) assert(retained[i].x.value==='retained-'+(1984+i), 'stored references');

// Repeated this loads include strict primitives, sloppy boxing and lexical this.
function strictThis() { 'use strict'; return this; }
function sloppyThis() { return this; }
var receiver={x:37, method:function() { return (()=>this.x)(); }};
for (var i=0; i<100; i++) {
    assert(strictThis.call('string-'+i)==='string-'+i, 'strict string this');
    assert(strictThis.call(null)===null, 'strict null this');
    assert(sloppyThis.call(17).valueOf()===17, 'sloppy boxed this');
    assert(receiver.method()===37, 'arrow this');
}
class Base { constructor() { this.x=19; } }
class Derived extends Base {
    constructor() {
        var rejected=false;
        try { this.x; } catch(e) { rejected=e instanceof ReferenceError; }
        assert(rejected, 'this before super');
        super();
        assert(this.x===19, 'this after super');
    }
}
for(var i=0;i<100;i++) new Derived();
print('PASS ordinary property fast paths');
