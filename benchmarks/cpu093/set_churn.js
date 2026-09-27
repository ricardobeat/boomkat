var c=new Set(),n=8192,steps=n*100;
for(var i=0;i<n;i++)c.add(i);
for(var k=n;k<n+steps;k++){if(!c.delete(k-n))throw new Error('delete');c.add(k);}
var sum=0;for(var q=0;q<2000000;q++){if(c.has(steps+q%n))sum++;if(c.has(q%n))sum+=3;}
if(sum!==2000000||c.size!==n)throw new Error('checksum '+sum);print('churn: passed');
