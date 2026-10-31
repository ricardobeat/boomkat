var kinds=[Int8Array,Uint8Array,Uint8ClampedArray,Int16Array,Uint16Array,Int32Array,Uint32Array,Float16Array,Float32Array,Float64Array];
var vals=[0,-0,1,-1,127,128,254,255,256,-128,-129,32767,32768,65535,65536,2147483647,2147483648,4294967295,-2147483649,16777217,1099511627775,140737488355327,-140737488355327,1.5,2.5,NaN,Infinity,-Infinity];
function storeRead(a,i,v){a[i]=v;return a[i];}
function fmt(v){return Object.is(v,-0)?'-0':String(v);}
for(var k=0;k<kinds.length;k++){
 var a=new kinds[k](vals.length), s=[];
 for(var i=0;i<vals.length;i++)s.push(fmt(storeRead(a,i,vals[i])));
 console.log(kinds[k].name+': '+s.join(','));
}
var convCalls=0, a=new Uint8Array(2), o={valueOf:function(){convCalls++;return 257;}};
a[0]=o; console.log('coerce '+a[0]+' '+convCalls);
var ab=new ArrayBuffer(4), view=new Uint8Array(ab);view[0]=5;ab.transfer();view[0]=9;console.log('detached '+String(view[0]));
var rab=new ArrayBuffer(8,{maxByteLength:16}), rv=new Uint8Array(rab);rv[7]=42;rab.resize(4);rv[7]=9;console.log('resized '+String(rv[7])+' '+rv.length);
var big=new BigInt64Array(1);var throws=false;try{big[0]=1;}catch(e){throws=e instanceof TypeError;}console.log('bigint '+throws);
