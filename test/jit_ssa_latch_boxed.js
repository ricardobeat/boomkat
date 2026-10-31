// Multiple values are defined inside the loop and read only after it. Their
// exit homes are boxed, and their converted backedge inputs coexist at the latch.
function boxedPressure(n) {
  var i=0, x0, x1, x2, x3, x4, x5, x6, x7;
  for (i=0; i<n; i++) {
    x0=(i*2)|0; x1=(i*3)|0; x2=(i*4)|0; x3=(i*5)|0;
    x4=(i*6)|0; x5=(i*7)|0; x6=(i*8)|0; x7=(i*9)|0;
  }
  return x0+','+x1+','+x2+','+x3+','+x4+','+x5+','+x6+','+x7;
}
for (var k=0; k<400; k++) {
  var n=1+(k%83), q=n-1;
  var expected=[(q*2)|0,(q*3)|0,(q*4)|0,(q*5)|0,
                (q*6)|0,(q*7)|0,(q*8)|0,(q*9)|0].join(',');
  var result=boxedPressure(n);
  if (result!==expected) throw Error(n+' '+result+' != '+expected);
}
print('boxed latch: PASS');
