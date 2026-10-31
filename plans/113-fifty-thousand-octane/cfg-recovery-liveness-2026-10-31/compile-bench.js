var start=Date.now(), sum=0;
for (var k=0;k<250;k++) {
  var f=Function('n','var i=0,s=0,t=0; for(i=0;i<n;i++){t=(i*3)|0;s=(s+t)|0;} return s; // '+k);
  sum+=f(300);
}
if(sum!==33637500)throw Error('wrong result '+sum);
print('compile-window: '+(Date.now()-start)+' ms');
