// An interior cyclic SSA budget exit must publish progress before retiring
// the plan, so already committed stencil stores are never replayed.
function makeActual(n){var rowSize=n+2;return function work(a,b){for(var k=0;k<20;k++){for(var j=1;j<=n;j++){var p=j*rowSize;var last=a[p];++p;for(var i=1;i<=n;i++){last=a[p]=(b[p]+last+a[++p])*.25;}}}};}
function makeReference(n){var rowSize=n+2;return function ref(a,b){eval("");for(var k=0;k<20;k++){for(var j=1;j<=n;j++){var p=j*rowSize;var last=a[p];++p;for(var i=1;i<=n;i++){last=a[p]=(b[p]+last+a[++p])*.25;}}}};}
var n=16,size=(n+2)*(n+2),actual=makeActual(n),reference=makeReference(n);
for(var round=0;round<20;round++) {
 var a=[],r=[],b=[];
 for(var i=0;i<size;i++){a[i]=r[i]=((i*19+round*13)%107)/107;b[i]=((i*31+round*3)%101)/101;}
 actual(a,b);reference(r,b);
 for(var i=0;i<size;i++)if(a[i]!==r[i])throw Error('stencil r='+round+' i='+i+' actual='+a[i]+' ref='+r[i]);
}
console.log('JIT nested store budget: PASS');
