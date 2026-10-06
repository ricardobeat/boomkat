function check(value, expected) { if (value !== expected) throw new Error(value + ' != ' + expected); }
function field(item) { return item.name; }
function pick(item, fallback) { const active = item.active; const name = item.name; return active ? name : fallback; }
function property(n, item) { let value = ''; for (let i = 0; i < n; i++) value = field(item); return value; }
function records(items, n) { let value = ''; for (let i = 0; i < n; i++) value = pick(items[i], value); return value; }
function dense(items, n) { let value = ''; for (let i = 0; i < n; i++) value = items[i]; return value; }
const items = [];
for (let i = 0; i < 200000; i++) items.push({active: !!(i & 1), name: 'item' + (i & 1)});
check(property(200000, {name: 'ok'}), 'ok');
check(records(items, items.length), 'item1');
check(dense(['a','b','c'], 3), 'c');
const mixed = items.slice();
mixed[1000] = {active: true, name: 'different', extra: 1};
check(records(mixed, mixed.length), 'item1');
let reads = 0;
Object.defineProperty(mixed[1000], 'name', {get() { reads++; return 'getter'; }});
check(records(mixed, mixed.length), 'item1');
check(reads, 1);
const holes = new Array(1000); holes[999] = 'last';
check(dense(holes, holes.length), 'last');
let effects = '';
function effect(x) { effects += x; return x; }
check(({a: effect('a'), b: effect('b')})['a'], 'a');
check([effect('c'), effect('d')][0], 'c');
check(effects, 'abcd');
check([1,,3][1], undefined);
check(({a: 1, a: 2})['a'], 2);
const receiver = [function () { return this; }];
check(receiver[0](), receiver);
check(([function () { return this.length; }])[0](), 1);
function inherited(n, item) { let value; for(let i=0;i<n;i++) value = field(item); return value; }
check(inherited(10000, Object.create({name: 'prototype'})), 'prototype');
function numericField(item) { return item.value * 2 + 1; }
function transform(n, item) { let sum=0; for(let i=0;i<n;i++) sum += numericField(item); return sum; }
check(transform(10000, {value: 3}), 70000);
check(transform(10000, {value: '3'}), 70000);
function localCopy(a) { let x = a; x += 1; return a; }
function repeated(n, value) { let result; for(let i=0;i<n;i++) result=localCopy(value); return result; }
check(repeated(10000, 3), 3);
function captureCopy(n) { let captured = 3; const f = () => { let x=captured; x+=1; return captured; }; let value; for(let i=0;i<n;i++) value=f(); return value; }
check(captureCopy(10000), 3);
console.log('native reads OK');
