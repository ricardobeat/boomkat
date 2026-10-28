var leafMask = 3;
function leafSet() { this.state = this.state | leafMask; }
function leafRead() { return (this.state & leafMask) !== 0 || this.state === 8; }
function leafChain() { return this.child.value * 2 + this.state; }
function LeafOwner() { this.state = 0; this.child = {value: 7}; }
LeafOwner.prototype.set = leafSet;
LeafOwner.prototype.read = leafRead;
LeafOwner.prototype.chain = leafChain;
var leafObject = new LeafOwner();
function leafDispatch(o) { o.set(); return o.read() ? o.chain() : -1; }
function leafNested(o) { return leafDispatch(o); }
for (var i = 0; i < 500; i++) {
  leafObject.state = i & 15;
  if (leafNested(leafObject) !== 14 + ((i & 15) | 3)) throw Error('SSA nested leaf');
}
leafMask = 4;
leafObject.state = 0;
if (leafNested(leafObject) !== 18) throw Error('SSA binding changed');
leafObject.child.value = 2.5;
if (leafNested(leafObject) !== 9) throw Error('SSA field representation');
var coercions = 0;
leafObject.state = {valueOf: function () { coercions++; return 1; }};
leafSet.call(leafObject);
if (leafObject.state !== 5 || coercions !== 1) throw Error('SSA setter replay');
leafObject.state = '2';
leafSet.call(leafObject);
if (leafObject.state !== 6) throw Error('SSA string replacement');
var sets = 0;
Object.defineProperty(leafObject, 'state', {get: function () {return 8;}, set: function (v) {sets++;}, configurable: true});
leafDispatch(leafObject);
if (sets !== 1) throw Error('SSA accessor replay');
Object.defineProperty(leafObject, 'state', {value: 2, writable: false, configurable: true});
leafSet.call(leafObject);
if (leafObject.state !== 2) throw Error('SSA read-only field');
var leafPrototype = {state: 0, set: leafSet, read: leafRead, child: {value: 1}, chain: leafChain};
var leafDerived = Object.create(leafPrototype);
leafPrototype.set();
if (leafDerived.state !== 4 || !leafDerived.read()) throw Error('SSA prototype epoch');
print('SSA leaves: PASS');
