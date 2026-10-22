function typed(a: number, b: number, c: number, d: number) { return ((a*b+c)/(d-a)+b*c)-a*d; }
function generic(a, b, c, d) { return ((a*b+c)/(d-a)+b*c)-a*d; }
function sum(a: number,b: number,c: number,d: number) { return a+b+c+d; }
function genericSum(a,b,c,d) { return a+b+c+d; }
function immediates(a: number,b: number) { return ((a+3)*-2-b/7)-4; }
function genericImmediates(a,b) { return ((a+3)*-2-b/7)-4; }
function rounding(a: number,b: number,c: number) { return (a+b)+c; }
function multiplyAdd(a: number,b: number,c: number) { return a*b+c; }
function identity(a: number) { return a; }
function constant(a: number) { return 0.5; }
function union(a: number|string,b: number) { return a+b; }
function optional(a?: number,b?: number) { return a+b; }
function defaulted(a: number=2,b: number=3) { return a+b; }
function rest(a: number,...b: number[]) { return a+b.length; }
function parameterWrite(a: number,b: number) { a=a+b; return a*b; }
function genericParameterWrite(a,b) { a=a+b; return a*b; }
let effects=0;
function effectful(a: number,b: number) { effects++; return a+b; }
function check(a,b,label) { if (!Object.is(a,b)) throw new Error(label+': '+a+' != '+b); }
const values=[0,-0,1,-1,0.5,-1.5,1e100,-1e100,1e-300,NaN,Infinity,-Infinity,140737488355327,-140737488355328,9007199254740991];
let count=0;
for (let i=0;i<values.length;i++) for(let j=0;j<values.length;j++) {
 const a=values[i], b=values[j], c=values[(i+j)%values.length], d=values[(i*3+j+1)%values.length];
 check(typed(a,b,c,d),generic(a,b,c,d),'arithmetic');
 check(sum(a,b,c,d),genericSum(a,b,c,d),'sum');
 check(immediates(a,b),genericImmediates(a,b),'immediate');
 check(parameterWrite(a,b),genericParameterWrite(a,b),'parameter write');
 count++;
}
check(rounding(1e16,-1e16,1),1,'association');
check(multiplyAdd(1.0000000000000002,0.9999999999999998,-1),0,'intermediate rounding');
check(sum(-0,-0,-0,-0),-0,'negative zero');
check(identity('wrong'),'wrong','identity fallback');
check(constant('wrong'),0.5,'constant');
check(union('x',2),'x2','union');
check(optional(undefined,2),NaN,'optional');
check(defaulted(),5,'defaults');
check(rest(3,4,5),5,'rest');
check(effectful('x',2),'x2','effectful fallback'); check(effects,1,'effect once');
for (const tuple of [['a','b','c','d'],[1n,2n,3n,4n],[true,false,null,undefined]]) {
 check(sum(...tuple),genericSum(...tuple),'non Number sum');
}
let order='';
const objectA={valueOf(){order+='a';return 1;}};
const objectB={valueOf(){order+='b';return 2;}};
check(sum(objectA,objectB,3,4),10,'coercion');check(order,'ab','coercion order/count');
let threw=false;
try { sum(Symbol(),2,3,4); } catch(e) { threw=e instanceof TypeError; }
check(threw,true,'symbol throws');
order='';threw=false;
const thrower={valueOf(){order+='x';throw 17;}};
try { sum(objectA,thrower,3,4); } catch(e) { threw=e===17; }
check(threw,true,'coercion exception');check(order,'ax','no replay');
for (const tuple of [[1n,2,3,4],[1,2n,3,4]]) {
 threw=false; try { sum(...tuple); } catch(e) { threw=e instanceof TypeError; } check(threw,true,'mixed bigint throws');
}
print('numeric-region regression',count,'OK');
