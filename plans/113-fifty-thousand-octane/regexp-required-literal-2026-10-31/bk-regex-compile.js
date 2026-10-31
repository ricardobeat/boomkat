var patterns=['(a|b)longliteral','(a|b)longliteral?', '^(?:alpha|beta)\\s+word', '(x|y)abcdefghijklmnopq?'];
var t=Date.now(), sum=0;
for(var i=0;i<1000000;i++) { var r=new RegExp(patterns[i&3]); if(r.test('alongliteral')) sum++; }
if(sum!==500000) throw Error('bad '+sum);
print('compile-regexp: '+(Date.now()-t)+' ms');
