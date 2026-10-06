function check(a,b) { if (!Object.is(a,b)) throw new Error(a+' != '+b); }
function numberBody(a,b,c) { return (a+b)*c-a; }
function loop(n,start,b,c) {
    let sum=0;
    for(let i=start;i<n;i++) sum+=numberBody(i,b,c);
    return sum;
}
check(loop(200000,0,3,2),20001100000);
check(loop(200000,-100,3,2),20001095550);
check(loop(100.5,0,3,2),5656);
check(loop(0,0,3,2),0);
check(loop(100,100,3,2),0);
let conversions=0;
const object={valueOf(){conversions++;return 2;}};
check(loop(100,0,3,object),5550);
check(conversions,100);
numberBody=function(a,b,c){return a+b+c;};
check(loop(200000,0,3,2),20000900000);
function direct(n,a) { let s=a; for(let i=0;i<n;i++) s+=i; return s; }
check(direct(200000,0),19999900000);
check(direct(300,-0),44850);
check(direct(100,Infinity),Infinity);
check(direct(100,NaN),NaN);
function changing(n) { let s=0; for(let i=0;i<n;i++) { s+=i; n--; } return s; }
check(changing(200000),4999950000);
function widerStep(n) { let s=0; for(let i=0;i<n;i+=2) s+=i; return s; }
check(widerStep(200000),9999900000);
function zero(n) { let z=-0; for(let i=0;i<n;i++) z*=1; return z; }
check(zero(200000),-0);
print('PASS native loops');
