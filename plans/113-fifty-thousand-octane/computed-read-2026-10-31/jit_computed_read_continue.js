// Dynamic data keys can continue natively after a shape/key miss. Slow cases
// must replay the read without invoking user code in the native helper.
function computedRead(o, key) { return o[key] + 1; }
var object={alpha:10,beta:20};
for (var i=0;i<500;i++) {
  if (computedRead(object,'alpha')!==11) throw Error('warm read');
  if (computedRead(object,'beta')!==21) throw Error('alternate read');
}
var proto={inherited:30};
var derived=Object.create(proto);
if (computedRead(derived,'inherited')!==31) throw Error('prototype');
proto.inherited=40;
if (computedRead(derived,'inherited')!==41) throw Error('prototype mutation');
var calls=0;
Object.defineProperty(object,'beta',{configurable:true,get:function(){calls++;return 22;}});
if (computedRead(object,'beta')!==23 || calls!==1) throw Error('getter replay');
var keyCalls=0;
var coercing={toString:function(){keyCalls++;return 'alpha';}};
if (computedRead(object,coercing)!==11 || keyCalls!==1) throw Error('key coercion');
var proxyCalls=0;
var proxy=new Proxy(object,{get:function(target,key){proxyCalls++;return target[key];}});
if (computedRead(proxy,'alpha')!==11 || proxyCalls!==1) throw Error('proxy replay');
var transient=('xalpha').slice(1);
if (computedRead(object,transient)!==11) throw Error('non-interned key');
var sym=Symbol('value'); object[sym]=50;
if (computedRead(object,sym)!==51) throw Error('symbol');
print('computed read continuation: PASS');
