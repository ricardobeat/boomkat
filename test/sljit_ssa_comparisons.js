// An int32 induction value compared with a widened body expression.
function mixedCompare(a, n) {
    var sum = 0;
    for (var i=0;i<n;i++) {
        if (i < a[i] + 0.5) sum += 1; else sum -= 1;
    }
    return sum;
}
var a=new Int32Array(32);for(var i=0;i<32;i++)a[i]=i;
for(var warm=0;warm<200;warm++) {
    var got=mixedCompare(a,32);
    if(got!==32)throw Error('mixed comparison '+got);
}
var unordered = new Float64Array(32); unordered.fill(NaN);
if (mixedCompare(unordered, 32) !== -32) throw Error('unordered comparison');
print('mixed comparison PASS');
