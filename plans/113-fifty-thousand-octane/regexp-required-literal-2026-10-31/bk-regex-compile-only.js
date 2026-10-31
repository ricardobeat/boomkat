var patterns=['(a|b)longliteral','(a|b)longliteral?', '^(?:alpha|beta)\\s+word', '(x|y)abcdefghijklmnopq?'];
var t=Date.now(), last;
for(var i=0;i<1000000;i++) last=new RegExp(patterns[i&3]);
if(last.source!==patterns[3]) throw Error('bad');
print('compile-only: '+(Date.now()-t)+' ms');
