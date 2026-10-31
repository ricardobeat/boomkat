function phiSwap(x,a,b,c) {
    var p=x+1, q=x+2, t;
    if(a) { p=p+3; q=q+4; } else { p=p-5; q=q-6; }
    if(b) { t=p; p=q; q=t; }
    if(c) { p=p+q; q=q+1; }
    return p*17+q;
}
function phiDrive(x,a,b,c) { return phiSwap(x,a,b,c)+0; }
function reference(x,a,b,c) {
    var p=x+1, q=x+2;
    if(a) { p+=3; q+=4; } else { p-=5; q-=6; }
    if(b) { var z=q; q=p; p=z; }
    if(c) { p+=q; q+=1; }
    return p*17+q+0;
}
var samples=[0,-0,1,-1,2.5,12345,2147483646,-2147483648,4294967295,NaN,Infinity,-Infinity,undefined,null,'2'];
for(var round=0; round<300; round++) for(var i=0;i<samples.length;i++) for(var bits=0;bits<8;bits++) {
    var a=!!(bits&1), b=!!(bits&2), c=!!(bits&4), x=samples[i];
    var got=phiDrive(x,a,b,c), expected=reference(x,a,b,c);
    if(!Object.is(got,expected)) throw Error('join mismatch '+round+' '+i+' '+bits+' '+got+' '+expected);
}
var effects=0; var obj={valueOf:function(){effects++;return 2;}};
var got=phiDrive(obj,true,true,true); if(got!==reference(2,true,true,true)||effects!==2) throw Error('coercion '+effects);
var savedPhiSwap=phiSwap;
effects=0;
var mutating={valueOf:function(){effects++;phiSwap=function(){return 99;};return 2;}};
if(phiDrive(mutating,true,true,true)!==reference(2,true,true,true)||effects!==2) throw Error('mutation recovery');
if(phiDrive(2,true,true,true)!==99) throw Error('changed callee');
phiSwap=savedPhiSwap;

function chooseValue(a,b,select) { var result=a; if(select) result=b; return result; }
function driveValue(a,b,select) { return chooseValue(a,b,select); }
for(var j=0;j<300;j++) {
    if(!Object.is(driveValue(-0,0,false),-0) || !Object.is(driveValue(-0,0,true),0)) throw Error('signed zero');
    if(driveValue('first','second',!!(j&1)) !== ((j&1)?'second':'first')) throw Error('string join');
}
console.log('join coalescing: PASS');
