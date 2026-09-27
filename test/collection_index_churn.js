function check(ok){if(!ok)throw new Error('collection index churn');}
var map=new Map(),set=new Set(),n=64;
for(var i=0;i<n;i++){map.set(i,i);set.add(i);}
var mi=map.keys(),si=set.values();check(mi.next().value===0&&si.next().value===0);
for(var k=n;k<6464;k++){
    check(map.delete(k-n)&&set.delete(k-n));map.set(k,k);set.add(k);
    if(k%37===0)check(map.get(k)===k&&set.has(k)&&!map.has(k-n));
}
check(map.size===n&&set.size===n);
check(mi.next().value===6400&&si.next().value===6400);
check(Array.from(map.keys()).join(',')===Array.from(set.values()).join(','));
for(var round=0;round<4;round++){
    map.clear();set.clear();
    for(var p=0;p<8;p++){map.set('r'+round+'k'+p,p);set.add('r'+round+'k'+p);}
    for(var q=0;q<8;q++)check(map.get('r'+round+'k'+q)===q&&set.has('r'+round+'k'+q));
}
var keys=[],objects=new Map();for(var a=0;a<128;a++){var key={a:a};keys.push(key);objects.set(key,a);}
for(var b=0;b<64;b++)check(objects.delete(keys[b]));
for(var c=64;c<128;c++)check(objects.get(keys[c])===c);
var mixed=new Set([undefined,null,NaN,-0,1,'1',true,false]);
for(var d=0;d<1000;d++){mixed.add('x'+d);mixed.delete('x'+d);}
check(mixed.size===8&&mixed.has(NaN)&&mixed.has(0)&&mixed.has(undefined));
var left=new Set(),right=new Set();for(var e=0;e<64;e++){left.add(e);right.add(e+32);}
check(left.difference(right).size===32&&left.symmetricDifference(right).size===64);
var mutate=new Map([[1,1],[2,2],[3,3]]),seen=[];
mutate.forEach(function(v,k){seen.push(k);if(k===1){mutate.delete(2);mutate.set(4,4);}});
check(seen.join(',')==='1,3,4');
print('PASS collection index churn');
