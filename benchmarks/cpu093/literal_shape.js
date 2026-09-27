function make(x,y){return {alpha:x,beta:y,gamma:x,delta:y};}
var sum=0;
for(var i=0;i<1500000;i++){var p=make(i,3);sum+=p.beta;}
if(sum!==4500000)throw new Error('checksum');
print('literal shape: passed');
