function calc(a,b,c,d){ var x=a+1; return x; }
var sum=0;for(var i=0;i<10000000;i++)sum+=calc(1,2,3,4);
if(sum!==20000000)throw new Error('checksum');print('trimmed frame: passed');
