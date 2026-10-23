function wrappingAdd(a, b) { return (a + b) | 0; }
function bitTest(x) { if ((x & 4) !== 0) return 1; return 0; }
function shiftedRead(a, p) { return a[p >> 2] | 0; }
function stateUpdate() { this.state = this.state | 4; }
function rotate(x) { return (x << 5) | (x >>> 27); }
function varChain(x) { var scale = 2; var offset = scale + 3; return x + offset; }
