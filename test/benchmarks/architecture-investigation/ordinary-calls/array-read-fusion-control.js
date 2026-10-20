// Integer dispatch control: immediate constants inside a scalar loop, with no
// indexed property reads that can trigger the LDINT + GETPROP fusion.
function scalarControl() {
    var sum = 0;
    for (var i = 0; i < 2000000; i++) {
        if ((i & 1) === 0) sum += 17;
        else sum += 23;
    }
    return sum;
}

var start = Date.now();
var result = scalarControl();
print("scalar_control: iterations=2000000 total=" + (Date.now() - start)
      + "ms checksum=" + result);
