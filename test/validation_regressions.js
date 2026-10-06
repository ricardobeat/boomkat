function check(condition, text) { if (!condition) throw new Error(text); }
function syntax(code) { let caught=false; try { Function(code); } catch(e) { caught=e instanceof SyntaxError; } check(caught, code); }
syntax('class A { #x; h(o) { return 1 + #x in o; }}');
syntax('async function* f() { for await (;;) ; }');
syntax('[{a = 0}.x] = [];');
let effect;
Object.defineProperty(Array.prototype, '1', {configurable:true, set(v) {effect=v;}});
const obj=Object.create(null); obj.key=1;
for ([0][1] in obj) {}
delete Array.prototype[1];
check(effect==='key', 'indexed inherited setter');
function blockArguments(code) { eval(code); { function arguments() {} } return typeof arguments; }
check(blockArguments('42')==='function', 'Annex B arguments');
const inferred = true && function() {};
check(inferred.name==='', 'logical expression name');
var receiver = 'global';
const target = {receiver:'object', tag() {return this.receiver;}};
check(target.tag``==='object', 'tag receiver');
check((true ? target.tag : null)``==='global', 'conditional tag receiver');
let failed=false;
try { class StrictHeader { [Object.preventExtensions({}).x=1]() {} } } catch(e) {failed=e instanceof TypeError;}
check(failed, 'strict class computed name');
let steps=0;
function infinite() { return { [Symbol.iterator]() {return this;}, next() {steps++; return {done:false, value:{x:steps}};} }; }
failed=false;
try { (function() {})(...infinite()); } catch(e) {failed=e instanceof RangeError;}
check(failed && steps===65536, 'bounded spread call');
console.log('validation regressions OK');
