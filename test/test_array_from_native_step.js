// Array.from steps intrinsic iterators by hand; results, holes, mutation during
// mapping, a patched next, and iterator closing must match the generic protocol.
function eq(a,b,m){ if (JSON.stringify(a)!==JSON.stringify(b)) throw new Error(m+": "+JSON.stringify(a)+" vs "+JSON.stringify(b)); }
eq(Array.from([1,2,3]), [1,2,3], "arr");
eq(Array.from([1,2,3], x=>x*2), [2,4,6], "map");
eq(Array.from(new Set([1,2,2,3])), [1,2,3], "set");
eq(Array.from(new Map([[1,2]])), [[1,2]], "map entries");
eq(Array.from("a\u{1F600}b"), ["a","\u{1F600}","b"], "str");
eq(Array.from([1,,3]).length, 3, "hole");
eq(Array.from([1,undefined,3]), [1,null,3], "undef");
eq(Array.from([1,2,3].keys()), [0,1,2], "keys");
eq(Array.from([5,6].entries()), [[0,5],[1,6]], "entries");
var a=[1,2,3]; eq(Array.from(a,(x,i)=>{ if(i==0) a.push(9); return x; }), [1,2,3,9], "grow");
var calls=0, orig=Object.getPrototypeOf([][Symbol.iterator]()).next;
Object.getPrototypeOf([][Symbol.iterator]()).next=function(){calls++; return orig.call(this);};
eq(Array.from([1,2]), [1,2], "patched"); eq(calls, 3, "patched calls");
Object.getPrototypeOf([][Symbol.iterator]()).next=orig;
var closed=0; var it=[1,2,3][Symbol.iterator](); it.return=function(){closed++; return {};};
try { Array.from({[Symbol.iterator](){return it;}}, ()=>{throw 1;}); } catch(e){}
eq(closed,1,"close");
class C { constructor(){ this.n=1; } }
eq(Array.from.call(C,[7,8]).length, 2, "ctor");
print("ok");
