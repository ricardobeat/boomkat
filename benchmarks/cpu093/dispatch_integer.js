function run(n){var sum=0;for(var i=0;i<n;i++)sum+=i;return sum;}
var total=0;for(var j=0;j<10;j++)total+=run(10000000);
if(total!==499999950000000)throw new Error('checksum');print('dispatch fastint: passed');
