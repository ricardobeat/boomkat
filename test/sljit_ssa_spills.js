// Loop-carried rotations must copy register and spill homes in parallel.
function ssaCycles(n) {
 var a0=1,a1=2,a2=3,a3=4,a4=5,a5=6,a6=7,a7=8,a8=9,a9=10,sum=0;
 for(var i=0;i<n;i++) {
  var t=a0;a0=a1;a1=a2;a2=a3;a3=a4;a4=a5;a5=a6;a6=a7;a7=a8;a8=a9;a9=t;
  sum+=a0;
 }
 return sum+a0+a1*2+a2*3+a3*4+a4*5+a5*6+a6*7+a7*8+a8*9+a9*10;
}
for(var warm=0;warm<200;warm++) {
 var x=ssaCycles(100);if(x!==935)throw Error('cycle100 '+x);
 var y=ssaCycles(101);if(y!==892)throw Error('cycle101 '+y);
}
if(ssaCycles(10001)!==55342)throw Error('poll cycle');
print('cycle PASS');
