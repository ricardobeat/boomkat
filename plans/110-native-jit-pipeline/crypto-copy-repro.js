function bnpDRShiftTo(n,r) {
  var this_array = this.array;
  var r_array = r.array;
  for(var i = n; i < this.t; ++i) r_array[i-n] = this_array[i];
  r.t = Math.max(this.t-n,0);
  r.s = this.s;
}


for(var sample=0;sample<400;sample++) {
 var n=sample%50+1,t=n*2;
 var x={array:[],t:t,s:0};
 for(var i=0;i<t;i++)x.array[i]=i<n?0:i*10017;
 bnpDRShiftTo.call(x,n,x);
 for(var i=0;i<n;i++)if(x.array[i]!=(n+i)*10017)throw new Error(sample+':'+i+':'+x.array[i]+' != '+((n+i)*10017));
}
print('copy PASS');
