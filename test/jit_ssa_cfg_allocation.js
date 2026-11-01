// Cyclic allocation: disjoint loop lifetimes, simultaneous phi sources,
// nested joins, mixed representations, and recovery after guarded arithmetic.
function AllocationBox() {}
var allocationPad = "var q0=0,q1=0,q2=0,q3=0,q4=0,q5=0,q6=0,q7=0,q8=0,q9=0," +
    "q10=0,q11=0,q12=0,q13=0,q14=0,q15=0,q16=0,q17=0,q18=0,q19=0," +
    "q20=0,q21=0,q22=0,q23=0,q24=0;";
AllocationBox.prototype.disjoint = new Function("n", allocationPad +
    "var s=0,i=0; while(i<n){s=s+i;i=i+1;}" +
    "var p=1,j=0; while(j<n){p=(p+j*3)|0;j=j+1;}" +
    "var t=0,k=n; while(k>0){t=t+k*2;k=k-1;}return s+p+t;");
AllocationBox.prototype.swap = new Function("n", "seed", allocationPad +
    "var a=seed,b=seed+1,c=seed+2,d=seed+3,i=0,t;" +
    "while(i<n){t=a;a=b;b=c;c=d;d=t;if(i&1){t=a;a=c;c=t;}" +
    "a=(a+i)|0;d=(d-i)|0;i=i+1;}return a*101+b*37+c*13+d;");
AllocationBox.prototype.nested = new Function("n", allocationPad +
    "var a=1,b=2,s=0,i=0,j,t;while(i<n){j=0;" +
    "while(j<3){t=a;a=b;b=t;if((i+j)&1){a=a+0.5;}else{b=b+1;}" +
    "s=s+a*0.25+b;j=j+1;}i=i+1;}return s+a+b;");
// The original argument must survive all prologue loads and each nested edge.
AllocationBox.prototype.arguments = new Function("n", "a", "b", "c", "d", "e", "f", allocationPad +
    "var i=0,s=0;while(i<n){if(i&1){s=s+a+b+c;}else{s=s+d+e+f;}" +
    "i=i+1;}return s+a*2+b*3+c*5+d*7+e*11+f*13;");

var allocationBox = new AllocationBox();
function allocationDisjoint(n) { return allocationBox.disjoint(n); }
function allocationSwap(n) { return allocationBox.swap(n, 3); }
function allocationNested(n) { return allocationBox.nested(n); }
function allocationArguments(n) { return allocationBox.arguments(n, 2, 3, 5, 7, 11, 13); }
var checksum = 0;
for (var round = 0; round < 3000; round++) {
    var n = (round & 7) + 1;
    var first = allocationDisjoint(n);
    var expected = n * (n - 1) * 2 + n * (n + 1) + 1;
    if (first !== expected) throw Error("disjoint lifetime " + round + ": " + first);
    checksum += first;
    var swapped = allocationSwap(n);
    var swapExpected = [0,670,694,1034,686,958,858,1322,850][n];
    if (swapped !== swapExpected) throw Error("cyclic swap " + n + ": " + swapped);
    checksum += swapped;
    var nested = allocationNested(n);
    var nestedExpected = [0,14.625,28.5,50.25,70.875,102.75,130.125,172.125,206.25][n];
    if (nested !== nestedExpected) throw Error("nested join " + n + ": " + nested);
    checksum += nested;
    var args = allocationArguments(n);
    var argExpected = Math.floor(n / 2) * 10 + Math.ceil(n / 2) * 31 + 377;
    if (args !== argExpected) throw Error("prologue inputs " + n + ": " + args);
    checksum += args;
}

// Exercise guard recovery after a loop has already produced new scalar state.
function recoverAllocation(n, start) {
    var a = start, b = 7, i = 0, before = 0;
    while (i < n) {
        var t = a; a = b; b = t;
        before = before + i;
        a = a + 1;
        i = i + 1;
    }
    return [a, b, before, i].join(",");
}
for (var warm = 0; warm < 2000; warm++) recoverAllocation(12, 3);
if (recoverAllocation(12, 2147483647) !== "2147483653,13,66,12") throw Error("overflow recovery");
if (recoverAllocation(3, "x") !== "9,x1,3,3") throw Error("coercion recovery");
print("SSA CFG allocation: PASS " + checksum);
