function* build(n) {var s='';for(var i=0;i<n;i++){s+='abcde';yield i;}return s;}
var start=Date.now(),it=build(40000),r,count=0;while(!(r=it.next()).done)count++;if(count!==40000||r.value!=='abcde'.repeat(40000))throw Error('checksum');print('TIME '+(Date.now()-start));print('CHECK '+r.value.length);
