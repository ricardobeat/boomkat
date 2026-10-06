function check(actual, expected) {
    if (!Object.is(actual, expected)) throw new Error(actual + ' != ' + expected);
}
function wide(a,b,c,d,e,f,g,h,i) { return a*b + c*d + e*f + g*h + i; }
for (let i=0; i<1000; i++) check(wide(1,2,3,4,5,6,7,8,9), 109);
check(wide(-0,1,-0,1,-0,1,-0,1,-0), -0);
function constant(a) { return (a + 123456.25) * -3.5; }
for (let i=0; i<1000; i++) check(constant(i), (i + 123456.25) * -3.5);
function writes(p,q) { p.x=1; q.x=2; p.x=3; return q.x; }
const p={x:0}, q={x:0};
for (let i=0; i<1000; i++) check(writes(p,q),2);
check(writes(p,p),3);
check(p.x,3);
function aliasRead(p,q) { p.x=p.x+1; return q.x+1; }
for (let i=0; i<1000; i++) check(aliasRead(p,q),3);
check(aliasRead(p,p),p.x+1);
function inherited(o) { return o.x*o.x+o.y; }
const proto={x:3,y:4}, obj=Object.create(proto);
for (let i=0; i<1000; i++) check(inherited(obj),13);
proto.x=5;
check(inherited(obj),29);
Object.setPrototypeOf(obj,{x:2,y:1});
check(inherited(obj),5);
let reads=0;
Object.defineProperty(obj,'x',{get(){reads++;return 7;},configurable:true});
check(inherited(obj),50);
check(reads,2);
function captureMaker(a) { return x => (x+a)*2; }
const one=captureMaker(1), ten=captureMaker(10);
for (let i=0; i<1000; i++) { check(one(i),(i+1)*2); check(ten(i),(i+10)*2); }
check(one('2'),42);
print('PASS copy patch');
