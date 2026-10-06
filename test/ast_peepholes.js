function eq(a,b) { if (!Object.is(a,b)) throw new Error(a+' != '+b); }
function sum({x,y},[a,b]) { return x+y+a+b; }
function run(n) { let s=0; for(let i=0;i<n;i++) s+=sum({x:i,y:1},[i,1]); return s; }
eq(run(10000),100010000);
sum=function(){return 7}; eq(run(10000),70000);
let effects='';
eq(((p)=>p.x+p.y)({x:(effects+='x',1),y:(effects+='y',2)}),3); eq(effects,'xy');
eq(((x,y)=>x*y+1)(3,4),13);
class P { constructor(){this.x=0;this.y=0;} move(x,y){this.x+=x;this.y+=y;return this;} }
function move(p,n){for(let i=0;i<n;i++) p.move(1,2);return p.x+p.y;}
eq(move(new P(),10000),30000);
let p=new P(); let gets=0;Object.defineProperty(p,'x',{get(){gets++;return 1},set(x){}});
eq(move(p,10),21);eq(gets,11);
print('PASS AST peepholes');
function projectedArray(src,n) {
    let len=0;
    for(let i=0;i<n;i++) { const a=[...src,i]; len+=a.length; }
    return len;
}
function projectedObject(obj,n) {
    let len=0;
    for(let i=0;i<n;i++) { const o={...obj,i}; len+=o.a; }
    return len;
}
eq(projectedArray([1,2,3],100),400);
let iterated=0;
const custom={*[Symbol.iterator](){iterated++;yield 1;yield 2;}};
eq(projectedArray(custom,10),30);eq(iterated,10);
let spreadGets=0;
eq(projectedObject({get a(){spreadGets++;return 3;}},10),30);eq(spreadGets,10);
eq(projectedObject({a:3,b:4},100),300);
let order='';
const coercion={ [Symbol.toPrimitive](hint){order+=hint;return 'x';} };
eq('a'+coercion+'b'+2,'axb2');eq(order,'default');
order='';eq(`a${`b${coercion}`}c`,'abxc');eq(order,'string');
let threw=false;try {'a'+Symbol()+'b';}catch(e){threw=e instanceof TypeError;}eq(threw,true);
eq(({x:(order+='1',4),y:(order+='2',5)}).x,4);eq(order,'string12');
class Base {constructor(x,y){this.x=x;this.y=y;}get mag(){return this.x*this.x+this.y*this.y;}}
class Derived extends Base {constructor(x,y,z){super(x,y);this.z=z;}get mag(){return super.mag+this.z*this.z;}}
function derived(n){let s=0;for(let i=0;i<n;i++)s+=new Derived(i,i,i).mag;return s;}
eq(derived(1000),998500500);
Object.defineProperty(Base.prototype,'mag',{get(){return 1;}});
eq(derived(1000),332834500);
print('PASS AST allocation candidates');
