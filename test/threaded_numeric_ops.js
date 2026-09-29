// Numeric and bitwise operators over edge-case operands (int32/fastint bounds,
// -0, NaN, doubles, strings, null/undefined). The checksum matches QuickJS.
var vals=[0,1,-1,2,7,-7,31,32,33,255,65535,2147483647,-2147483648,2147483648,4294967295,4294967296,1073741823,1073741824,-1073741824,-1073741825,140737488355327,-140737488355328,3.5,-3.5,0.5,-0.5,1e10,-0,NaN,Infinity,-Infinity,"5",true,null,undefined,"abc"];
function run(a,b){
  var r=[];
  r.push(a-b);r.push(a*b);r.push(a%b);r.push(a&b);r.push(a|b);r.push(a^b);r.push(a<<b);r.push(a>>b);r.push(a>>>b);
  var c=a; c=c-b; r.push(c); var d=a; d=d*b; r.push(d); var e=a; e=e>>>b; r.push(e);
  return r;
}
var out=[];
for(var i=0;i<vals.length;i++)for(var j=0;j<vals.length;j++){
  var r=run(vals[i],vals[j]);
  for(var k=0;k<r.length;k++){var x=r[k];out.push(Object.is(x,-0)?"-0":String(x));}
}
var h=0,s=out.join(",");
for(var i=0;i<s.length;i++)h=(h*31+s.charCodeAt(i))|0;
if (out.length !== 15552 || h !== -648940120) throw new Error("numeric operators diverge: " + out.length + " " + h);
