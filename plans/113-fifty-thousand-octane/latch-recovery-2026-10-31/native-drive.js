function step(n) {
  this.calls++;
  var value=n;
  for (var i=0;i<4;i++) value+=i;
  return value+this.payload;
}
function drive(object,count) {
  var result=0;
  for (var i=0;i<count;i++) result+=object.step(i);
  return result;
}
var o={calls:0,payload:1,step:step};
for(var warm=0;warm<50;warm++) if(drive(o,400)!==82600)throw Error('warm');
o.calls=0;
var start=Date.now(),sum=0;
for(var j=0;j<20000;j++) sum+=drive(o,400);
if(sum!==1652000000 || o.calls!==8000000)throw Error('bad '+sum+' '+o.calls);
print('native-drive: '+(Date.now()-start)+' ms');
