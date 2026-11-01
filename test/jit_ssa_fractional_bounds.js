// Fractional bounds crossing cyclic SSA phis must retain their value. A bound
// of 16.5 must never become 16 and spuriously clamp a result of 16.4.
function makeActual(width,height){var rowSize=width+2;function set_bnd(b,d){};    function advect(b, d, d0, u, v, dt)
    {var Wdt0=dt*width,Hdt0=dt*height,Wp5=width+.5,Hp5=height+.5;for(var j=1;j<=height;j++){var pos=j*rowSize;for(var i=1;i<=width;i++){var x=i-Wdt0*u[++pos];if(x>Wp5)x=Wp5;d[pos]=x;}}set_bnd(b,d);}

return advect;}
function makeReference(width,height){var rowSize=width+2;function set_bnd(b,d){};    function advect(b, d, d0, u, v, dt)
    {eval("");var Wdt0=dt*width,Hdt0=dt*height,Wp5=width+.5,Hp5=height+.5;for(var j=1;j<=height;j++){var pos=j*rowSize;for(var i=1;i<=width;i++){var x=i-Wdt0*u[++pos];if(x>Wp5)x=Wp5;d[pos]=x;}}set_bnd(b,d);}

return advect;}
var n=16,size=(n+2)*(n+2),actual=makeActual(n,n),reference=makeReference(n,n);
for(var round=0;round<30;round++){
var a=[],expected=[],src=[],u=[],v=[];
for(var i=0;i<size;i++){a[i]=expected[i]=0;src[i]=((i*19+round*3)%107)/107;u[i]=((i*11)%17-8)/32;v[i]=((i*7)%23-11)/32;}
var uu=round%3===1?src:u,vv=round%3===2?src:v;
actual(2,a,src,uu,vv,.1);reference(2,expected,src,uu,vv,.1);
var maxerr=0,at=-1;for(var i=0;i<size;i++){var e=Math.abs(a[i]-expected[i]);if(e>maxerr){maxerr=e;at=i;}}
if(maxerr>1e-12){console.log('BAD advect',round,maxerr,at,a[at],expected[at]);throw 'advect mismatch';}
}


function derivedBound(out, input, upper, count) {
    var bound = upper * 1;
    for (var index = 0; index < count; index++) {
        var value = input * 1;
        if (value > bound) value = bound;
        out[index] = value;
    }
}
var boundOutput = [];
for (var index = 0; index < 32; index++) boundOutput[index] = 0;
for (var warm = 0; warm < 64; warm++) derivedBound(boundOutput, 0.25, 1.5, 32);
var boundCases = [[16.4,16.5],[1.25,0.5],[1.25,-0.5],[1.25,-0],[-0,0],
    [-0.25,-0],[2147483647.25,2147483647.5],[-2147483648.25,-2147483648.5]];
for (var caseIndex = 0; caseIndex < boundCases.length; caseIndex++) {
    var input = boundCases[caseIndex][0], upper = boundCases[caseIndex][1];
    var expectedBound = input > upper ? upper : input;
    derivedBound(boundOutput, input, upper, 32);
    for (var index = 0; index < 32; index++) {
        if (!Object.is(boundOutput[index], expectedBound)) {
            throw Error("derived bound " + caseIndex + ":" + index);
        }
    }
}
console.log("JIT fractional bounds: PASS");
