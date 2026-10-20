var values=[]; for(var i=0;i<100;i++) values.push(i);
function f(x) { return x+1; }
function nested(depth, count) { if(depth) return nested(depth-1,count)+1; var sum=0;for(var j=0;j<count;j++)sum+=values.map(f)[99];return sum; }
var start=Date.now();var sum=nested(128,3000);if(sum!==300128)throw Error('checksum');print('CHECK '+sum);print('TIME '+(Date.now()-start));
