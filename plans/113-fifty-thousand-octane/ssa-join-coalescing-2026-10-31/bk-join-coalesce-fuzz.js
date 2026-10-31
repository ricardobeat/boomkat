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
console.log('join coalescing: PASS');
