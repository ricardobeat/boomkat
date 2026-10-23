function assert(value) { if (!value) throw new Error('function prototype'); }
function F() {}
var descriptor=Object.getOwnPropertyDescriptor(F,'prototype');
assert(typeof descriptor.value==='object' && descriptor.value===F.prototype);
assert(descriptor.writable && !descriptor.enumerable && !descriptor.configurable);
assert(F.prototype.constructor===F);
assert(Object.getPrototypeOf(F.prototype)===Object.prototype);
function G() {}
G.prototype=undefined;
assert(G.prototype===undefined && Object.getOwnPropertyDescriptor(G,'prototype').value===undefined);
assert(Object.getPrototypeOf(new G())===Object.prototype);
function H() {}
var custom={custom:true}; H.prototype=custom;
assert(H.prototype===custom && Object.getPrototypeOf(new H())===custom);
function J() {}
delete J.name; delete J.length;
assert(J.prototype.constructor===J);
function K() {}
assert(Reflect.ownKeys(K).indexOf('prototype')>=0);
assert(Object.getOwnPropertyDescriptors(K).prototype.value===K.prototype);
assert(!Reflect.deleteProperty(K,'prototype'));
function L() {}
Object.defineProperty(L,'prototype',{value:undefined});
assert(L.prototype===undefined);
function M() {}
Object.defineProperty(M,'prototype',{writable:false});
assert(typeof M.prototype==='object' && !Object.getOwnPropertyDescriptor(M,'prototype').writable);
var bound=F.bind(null);
assert(bound.prototype===undefined && new bound() instanceof F);
var arrow=()=>1;
assert(!Object.prototype.hasOwnProperty.call(arrow,'prototype'));
var getterCalls=0;
function reader(f) { return f.prototype; }
var functions=[];
for(var i=0;i<3000;i++) functions.push(function temporary(){});
for(var i=0;i<functions.length;i++) assert(reader(functions[i]).constructor===functions[i]);
print('PASS');
