function check(ok) { if (!ok) throw new Error('arrow capture cells'); }
var factory = (value) => {
    var state = value;
    return { get: () => state, set: (x) => { state = x; }, param: () => value };
};
var a = factory(1), b = factory(2);
a.set({ tag: 7 });
for (var i=0;i<10000;i++) { var junk = {i:i}; }
check(a.get().tag === 7 && a.param() === 1 && b.get() === 2);
var nested = (x) => () => () => ++x;
var inc = nested(3)(); check(inc() === 4 && inc() === 5);
function lexical(x) {
    var maker = () => { var value=x; return () => [this, arguments[0], ++value, new.target]; };
    return maker();
}
var receiver={};var f=lexical.call(receiver,9);
var r=f();check(r[0]===receiver && r[1]===9 && r[2]===10 && r[3]===undefined);
var shadow = (x) => { var read=()=>x; { let x=20; check((()=>x)()===20); } return read; };
check(shadow(8)()===8);
var dynamic = (x) => { var read=()=>x; eval('x=42'); return read; };
check(dynamic(1)()===42);
var withScope=(x)=>{var read=()=>x;with({x:33}){check(x===33);}return read;};
check(withScope(10)()===10);
var loops=[];var makeLoops=()=>{for(let j=0;j<4;j++)loops.push(()=>j);};makeLoops();
check(loops[0]()===0 && loops[3]()===3);
var strictFactory=(x)=>{'use strict';return ()=>++x;};check(strictFactory(5)()===6);
print('PASS arrow capture cells');
