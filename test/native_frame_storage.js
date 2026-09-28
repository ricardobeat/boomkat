function check(v, label) { if (!v) throw new Error(label); }
function descend(n, fn) {
    var sentinel = 'frame:' + n;
    var result = n ? descend(n - 1, fn) : fn();
    check(sentinel === 'frame:' + n, 'caller survives');
    return result + 1;
}
function callback(x) {
    var saved = 'callback:' + x;
    var result = [x].map(function(y) {
        return descend(100, function() {return y + 1;});
    });
    check(saved === 'callback:' + x, 'nested callback');
    return result[0];
}
check(descend(40, function() {return [7].map(callback)[0];}) === 150, 'return through callbacks');
var finalized = 0;
try {
    descend(80, function() {
        return [1].map(function() {try {throw new Error('nested');} finally {finalized++;}});
    });
} catch (e) {check(e.message === 'nested', 'exception identity');}
check(finalized === 1, 'finally');
check(descend(20, function() {return [1].map(function(x) {return x;})[0];}) === 22, 'reuse after throw');
class Base {constructor(v) {this.v = v;}}
class Derived extends Base {
    constructor(v) {
        var self = () => this;
        [v].forEach(x => {super(x);});
        check(self().v === v, 'derived this through callback');
    }
}
check(new Derived(19).v === 19, 'construct');
function* gen() {yield [2].map(callback)[0]; yield 'done';}
var it = gen();
check(it.next().value === 104 && it.next().value === 'done' && it.next().done, 'generator');
var seen = [];
Promise.resolve(3).then(function(x) {seen.push(descend(20, function() {return x;}));});
Promise.resolve().then(function() {check(seen[0] === 24, 'microtask reentry');});
function overflow(n) {
    if (n) return overflow(n - 1) + 1;
    return [0].map(function() {return overflow(80);})[0] + 1;
}
var overflowCaught = false;
try {overflow(80);} catch (e) {overflowCaught = e instanceof RangeError;}
check(overflowCaught, 'shared frame limit throws');
check([3].map(function(x) {return x + 1;})[0] === 4, 'reuse after overflow');
print('native frame storage PASS');
