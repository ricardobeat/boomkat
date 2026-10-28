// A guard must reconstruct the unboxed operand before interpreter replay.
// Fresh/growing arrays force exits after the interpreter has run part of a loop.
function B(arr, t, s) { this.array = arr; this.t = t; this.s = s; }
B.prototype.dlShiftTo = function ssaShift(n, r) {
  var this_array = this.array;
  var r_array = r.array;
  var i;
  for (i = this.t - 1; i >= 0; --i) r_array[i+n] = this_array[i];
  for (i = n - 1; i >= 0; --i) r_array[i] = 0;
  r.t = this.t + n;
  r.s = this.s;
};
for (var repeat=0; repeat<500; repeat++) {
 var b=new B([1,2,3],3,0), c=new B([],0,0);
 b.dlShiftTo(2,c);
 if(c.array.join(',')!=='0,0,1,2,3')throw new Error('shift '+repeat+': '+c.array.join(','));
 b.dlShiftTo(2,c);
 if(c.array.join(',')!=='0,0,1,2,3')throw new Error('second '+repeat+': '+c.array.join(','));
}
print('SSA recovery: PASS');
