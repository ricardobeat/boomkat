function check(ok){if(!ok)throw new Error('collection index boundary');}
var sizes=[7,8,9,15,16,17,255,256,257];
for(var nidx=0;nidx<sizes.length;nidx++){
    var n=sizes[nidx],m=new Map(),s=new Set();
    for(var i=0;i<n;i++){m.set(i,i+1);s.add(i);}
    for(var round=0;round<3;round++)for(var j=0;j<n;j++)check(m.get(j)===j+1&&s.has(j));
    check(!m.has(n)&&!s.has(n));
    for(var k=0;k<n;k+=2){check(m.delete(k)&&s.delete(k));}
    for(var q=0;q<n;q++)check(m.has(q)===(q%2===1)&&s.has(q)===(q%2===1));
}
print('PASS collection index boundary');
