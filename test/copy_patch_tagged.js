function assert(x) { if (!x) throw new Error('tagged region mismatch'); }
function choose(flag,a,b) { return flag?a:b; }
function select(n,a,b) {
    let value=a;
    for(let i=0;i<n;i++) value=choose(i&1,a,b);
    return value;
}
const obj={label:'object'};
assert(select(200001,'hello',obj)===obj);
assert(select(200000,'hello',obj)==='hello');
assert(select(200000,undefined,null)===undefined);
assert(select(200001,undefined,null)===null);
assert(select(200000,true,false)===true);
assert(select(200001,true,false)===false);
assert(select(200000,Symbol.for('left'),Symbol.for('right'))===Symbol.for('left'));
assert(select(200001,123n,456n)===456n);
assert(select(200000,NaN,Infinity)!==select(200000,NaN,Infinity));
assert(Object.is(select(200000,-0,1),-0));
function captured(n,a,b) {
    let value=a;
    const peek=()=>value;
    const pick = (flag,fallback) => flag?value:fallback;
    for(let i=0;i<n;i++) value=pick(i&1,b);
    return peek();
}
assert(captured(200000,'hello',obj)===obj);
function numeric(n) {
    let sum=0;
    const peek=()=>sum;
    for(let i=0;i<n;i++) sum=peek()+i;
    return sum;
}
assert(numeric(200000)===19999900000);
assert(select(0,'a','b')==='a');
assert(select(1,'a','b')==='b');
console.log('tagged regions OK');
