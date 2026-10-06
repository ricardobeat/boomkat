function eq(actual, expected) {
    if (!Object.is(actual, expected)) throw new Error(String(actual) + ' != ' + String(expected));
}
function throws(fn, type) {
    let caught = false;
    try { fn(); } catch (e) { if (!(e instanceof type)) throw e; caught = true; }
    eq(caught, true);
}

let order = '';
eq(({a: (order += 'a', 1), b: (order += 'b', 2), a: (order += 'c', 3)}).a, 3);
eq(order, 'abc');
let local = 4;
eq(({a: local, b: (local = 9)}).a, 4);
eq(local, 9);
throws(() => ({a: 1, b: (() => { throw new RangeError(); })()}).a, RangeError);
eq(({f: function(){}}).f.name, 'f');
eq(({f: () => 1}).f.name, 'f');
eq(({C: class {}}).C.name, 'C');
eq(({a: -0}).a, -0);
eq(({a: NaN}).a, NaN);
eq(({a: 1n}).a, 1n);
let symbol = Symbol('x');
eq(({a: symbol}).a, symbol);
let retained = ({a: {nested: 7}, b: new Array(100)}).a;
eq(retained.nested, 7);
eq(({a: function(){return this.b;}, b: 8}).a(), 8);
eq(({a(){return this.b;}, b: 9}).a(), 9);
eq(({get a(){return 10;}}).a, 10);
eq(({__proto__: {a: 11}}).a, 11);
eq(({['a']: 12}).a, 12);
eq(delete ({a: 1}).a, true);
eq((({a: 1}).a = 13), 13);
eq(++({a: 1}).a, 2);
eq(typeof ({a: 1}).a, 'number');

function arrayLength(source, tail) {
    let result;
    { const temporary = [...source, tail]; result = temporary.length; }
    return result;
}
function objectValue(source, tail) {
    let result;
    { const temporary = {...source, tail}; result = temporary.a; }
    return result;
}
function arraySum(source) {
    let result = 0;
    for (let i = 0; i < 100; i++) { const temporary = [...source, i]; result += temporary.length; }
    return result;
}
function objectSum(source) {
    let result = 0;
    for (let i = 0; i < 100; i++) { const temporary = {...source, i}; result += temporary.a; }
    return result;
}
eq(arrayLength([1, 2], 3), 3);
eq(arraySum([1, 2]), 300);
eq(arrayLength([], 3), 1);
eq(arrayLength([undefined, , 3], 4), 4);
eq(arrayLength('abc', 0), 4);
throws(() => arrayLength(null, 0), TypeError);
eq(objectValue({a: 4}, 0), 4);
eq(objectSum({a: 4}), 400);
eq(objectValue({a: retained}, 0), retained);
eq(objectValue({a: symbol}, 0), symbol);
eq(objectValue({a: -0}, 0), -0);
eq(objectValue({a: undefined}, 0), undefined);
eq(objectValue(Object.create({a: 4}), 0), undefined);
eq(objectValue(null, 0), undefined);
const hidden = Object.defineProperty({b: 2}, 'a', {value: 9});
eq(objectValue(hidden, 0), undefined);
let gets = 0;
eq(objectValue({a: 3, get b(){gets++; return 2;}}, 0), 3);
eq(gets, 1);
let access = {get a(){gets++; return 7;}};
eq(objectValue(access, 0), 7); eq(gets, 2);
let accessorSymbol = Symbol();
let symbolSource = {a: 8};
Object.defineProperty(symbolSource, accessorSymbol, {enumerable: true, get(){gets++; return 1;}});
eq(objectValue(symbolSource, 0), 8); eq(gets, 3);
let changing = {get a(){delete this.b; return 12;}, b: 5};
eq(objectValue(changing, 0), 12);
let dict = {a: 23, b: 2, c: 3}; delete dict.b;
eq(objectValue(dict, 0), 23);
let indexed = {a: 24, 0: 1, 3: 4};
eq(objectValue(indexed, 0), 24);
order = '';
let proxy = new Proxy({a: 6}, {
    ownKeys(target){order += 'k'; return Reflect.ownKeys(target);},
    getOwnPropertyDescriptor(target, key){order += 'd'; return Reflect.getOwnPropertyDescriptor(target, key);},
    get(target, key){order += 'g'; return target[key];}
});
eq(objectValue(proxy, 0), 6); eq(order, 'kdg');
let iterated = 0;
let iterable = {*[Symbol.iterator](){iterated++; yield 1; yield 2;}};
eq(arrayLength(iterable, 0), 3); eq(iterated, 1);
let custom = [1, 2]; custom[Symbol.iterator] = function*(){yield 9;};
eq(arrayLength(custom, 0), 2);
let denseGetter = [1, 2];
Object.defineProperty(denseGetter, '0', {get(){gets++; return 5;}});
eq(arrayLength(denseGetter, 0), 3); eq(gets, 4);
let savedIterator = Array.prototype[Symbol.iterator];
try {
    Array.prototype[Symbol.iterator] = function*(){yield 1;};
    eq(arrayLength([1, 2, 3], 0), 2);
} finally { Array.prototype[Symbol.iterator] = savedIterator; }
let iteratorProto = Object.getPrototypeOf([][Symbol.iterator]());
let savedNext = iteratorProto.next;
try {
    iteratorProto.next = function(){return {done: true};};
    eq(arrayLength([1, 2, 3], 0), 1);
} finally { iteratorProto.next = savedNext; }

// A closure or eval must retain the actual container binding.
function captured(source) {
    let result;
    { const temporary = {...source}; result = (() => temporary)(); }
    return result;
}
eq(captured({a: 8}).a, 8);
function evaluated(source) {
    let result;
    { const temporary = {...source}; result = eval('temporary'); }
    return result;
}
eq(evaluated({a: 9}).a, 9);
function capturedTail(source) {
    let inspect;
    Object.defineProperty(source, 'a', {enumerable: true, get(){inspect = () => temporary; return 7;}});
    const temporary = {...source};
    return inspect() === temporary;
}
eq(capturedTail({}), true);
function tdz(source) {
    let result;
    { const temporary = [...source, temporary]; result = temporary.length; }
    return result;
}
throws(() => tdz([1]), ReferenceError);
function overwritten(source) {
    let result;
    { const temporary = {...source, a: 9}; result = temporary.a; }
    return result;
}
eq(overwritten({a: 1}), 9);
function withTail(source, scope) {
    let result;
    with (scope) { const temporary = {...source, tail}; result = temporary.a; }
    return result;
}
eq(withTail({a: 17}, {tail: 8}), 17);

// Tail reads can invoke global accessors after the spread snapshot.
let mutable = {a: {n: 7}};
let original = mutable.a;
Object.defineProperty(globalThis, 'allocationTail', {configurable: true, get(){mutable.a = 99; return 0;}});
function snapshot(source) {
    let result;
    { const temporary = {...source, allocationTail}; result = temporary.a; }
    return result;
}
eq(snapshot(mutable), original);
delete globalThis.allocationTail;
for (let i = 0; i < 1000; i++) {
    eq(objectValue({a: {n: i}}, 0).n, i);
    eq(({a: {n: i}, b: {n: i+1}}).a.n, i);
}
print('PASS AST allocation elimination');
let declarations = '';
let constants = '';
for (let i = 0; i < 280; i++) {
    declarations += 'let v' + i + '=' + i + ';';
    constants += '"constant' + i + '";';
}
let wide = new Function('source', declarations + 'let result; {const tmp={...source};result=tmp.a;} return result+v279;');
eq(wide({a: 3}), 282);
let largePool = new Function('source', constants + 'let result; {const tmp={...source};result=tmp.a;} return result;');
eq(largePool({a: 6}), 6);
let wideLiteral = new Function(declarations + 'return ({a:v278,b:(v278=0)}).a+v279;');
eq(wideLiteral(), 557);
print('PASS wide allocation operands');
