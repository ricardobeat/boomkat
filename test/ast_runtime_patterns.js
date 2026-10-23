(function () {
function same(a, b) { if (!Object.is(a, b)) throw new Error(String(a) + ' != ' + String(b)); }
function throws(f) { var ok = false; try { f(); } catch (e) { ok = e instanceof TypeError; } if (!ok) throw new Error('expected TypeError'); }
function add(a,b) { return (a+b)|0; }
function sub(a,b) { return (a-b)|0; }
function addi(a) { return (a+7)|0; }
function subi(a) { return (a-7)|0; }
function identity(a) { return (a&7)|0; }
function big(a,b) { return (a&b)|0; }
function test(a,b) { if ((a&b)!==0) return 7; return 9; }
function testi(a) { if ((a&4)===0) return 7; return 9; }
function read(a,p) { return a[p>>2]; }
function readu(a,p) { return a[p>>>2]; }
function write(a,p,v) { a[p>>2]=v; return a[p>>2]; }
var values = [0,-0,2147483647,2147483648,-2147483649,4294967295,2**47-1,-(2**47),1.25,NaN,Infinity,'12',null,undefined,true];
for (var i=0;i<values.length;i++) {
    var v=values[i];
    same(add(v,7),(v+7)|0); same(sub(v,7),(v-7)|0);
    same(addi(v),(v+7)|0); same(subi(v),(v-7)|0);
    same(identity(v),(v&7)|0); same(test(v,4),(v&4)!==0?7:9); same(testi(v),(v&4)===0?7:9);
}
throws(function(){add(1n,2n)}); throws(function(){sub(1n,2n)});
throws(function(){identity(1n)}); throws(function(){big(1n,2n)});
var count=0, object={valueOf:function(){count++;return 3;}};
same(add(object,7),10);same(count,1);same(test(object,4),9);same(count,2);
var constructors=[Int8Array,Uint8Array,Uint8ClampedArray,Int16Array,Uint16Array,Int32Array,Uint32Array,Float32Array,Float64Array];
for(var j=0;j<constructors.length;j++) {
    var a=new constructors[j](4); a[1]=12;
    same(read(a,7),12);same(readu(a,7),12);same(read(a,-4),undefined);same(readu(a,-4),undefined);same(read(a,100),undefined);
    same(write(a,4,23),23);same(write(a,100,23),undefined);
    same(write(a,4,{valueOf:function(){count++;return 8;}}),8);
}
same(count,11);
var plain=[1,2,3];same(read(plain,4),2);same(write(plain,4,9),9);
var log='';var proxy=new Proxy({1:6},{get:function(t,k){log+=k;return t[k];},set:function(t,k,v){log+='s'+k;t[k]=v;return true;}});
same(read(proxy,{valueOf:function(){log+='i';return 4;}}),6);same(log,'i1');
same(write(proxy,4,8),8);same(log,'i1s11');
var r=new Int32Array(2);r[1]=4;
function post(a,i) { var v=a[i++];return v+i; }
same(post(r,1),6);
print('runtime patterns PASS');
})();
