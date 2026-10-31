function nbits(x) {
  var r = 1, t;
  if((t=x>>>16) != 0) { x = t; r += 16; }
  if((t=x>>8) != 0) { x = t; r += 8; }
  if((t=x>>4) != 0) { x = t; r += 4; }
  if((t=x>>2) != 0) { x = t; r += 2; }
  if((t=x>>1) != 0) { r += 1; }
  return r;
}
function nbitsDriver(x) { return nbits(x); }
var sum=0, start=Date.now();
for(var i=0;i<10000000;i++) sum+=nbitsDriver((i*2654435761)>>>0);
print('nbits: '+(Date.now()-start)+' ms; sum='+sum);
