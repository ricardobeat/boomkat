var m=new Map(),s=new Set();for(var i=0;i<100000;i++){m.set(i,i);s.add(i);}
var sum=0;for(var j=0;j<100000;j++){sum+=m.get(j);if(!s.has(j))throw new Error('set');}
if(sum!==4999950000)throw new Error('checksum');print('append: passed');
