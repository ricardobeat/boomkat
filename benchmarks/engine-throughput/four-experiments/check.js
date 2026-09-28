function assert(x, msg) { if (!x) throw new Error(msg); }
function mul(a,b) { return a*b; }
assert(Object.is(mul(0,-1),-0), 'negative zero');
assert(Object.is(mul(-0,3),-0), 'double negative zero');
assert(mul(140737488355327,140737488355327) === 140737488355327*140737488355327, 'large multiply');
assert(mul(3.5,2)===7 && mul('3',2)===6, 'number and coercion');
assert(mul(3n,2n)===6n, 'bigint');
assert(isNaN(mul(NaN,2)) && isNaN(mul(Infinity,0)), 'nan');
var mixed=false;try{mul(1n,2);}catch(e){mixed=e instanceof TypeError;}assert(mixed,'mixed bigint');
var order=[];var a=[(order.push(1),1),undefined,,(order.push(2),2),...[3,4],,5];
assert(a.length===8 && 1 in a && !(2 in a) && !(6 in a) && a[7]===5 && order.join(',')==='1,2','array presence and order');
Object.defineProperty(Array.prototype,'0',{value:99,configurable:true,writable:false});
var b=[7,8];delete Array.prototype[0];assert(b[0]===7,'prototype nonwritable');
var x=[undefined,undefined];assert(Object.keys(x).join(',')==='0,1','undefined keys');
var kept=[];
for(var i=0;i<30000;i++){var s='value-'+i;var o={a:s,b:i,c:{x:i}};var aa=[s,o,[i,i+1]]; if(i%1000===0)kept.push(aa);}
for(var i=0;i<kept.length;i++){assert(kept[i][0]==='value-'+i*1000 && kept[i][1].c.x===i*1000 && kept[i][2][1]===i*1000+1,'retention');}
print('PASS experiments');
