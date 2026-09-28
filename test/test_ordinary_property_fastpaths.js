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
