function phiProbe(n) {
  var i=0, t=0;
  for (i=0;i<n;i++) t=(i*3)|0;
  return 4;
}
for (var j=0;j<400;j++) if(phiProbe(30)!==4) throw Error('result');
print('PASS');
