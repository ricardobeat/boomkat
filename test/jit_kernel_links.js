// A typed-memory region with enough guards to overflow the old fixup table.
var kernelSource = 'function linkedKernel(a,n){var s=0;for(var i=0;i<n;i++){';
for (var part = 0; part < 24; part++) {
    kernelSource += 's=(s+a[(i+' + part + ')&63])|0;';
}
kernelSource += '}return s;}';
eval(kernelSource);
var kernelArray = new Int32Array(64);
for (var i = 0; i < 64; i++) kernelArray[i] = i;
for (var warm = 0; warm < 100; warm++) {
    if (linkedKernel(kernelArray, 32) !== 20736) throw new Error('typed kernel');
}
kernelArray[17] = 2147483647;
if (linkedKernel(kernelArray, 32) !== 20412) throw new Error('int32 overflow');
var kernelObjects = [];
for (var i = 0; i < 64; i++) kernelObjects[i] = i;
var kernelCoercions = 0;
kernelObjects[0] = { valueOf: function () { kernelCoercions++; return 5; } };
if (linkedKernel(kernelObjects, 4) !== 1253 || kernelCoercions !== 1)
    throw new Error('kernel side exit replay');
kernelArray[17] = 17;
if (linkedKernel(kernelArray, 32) !== 20736) throw new Error('kernel reentry');
console.log('JIT kernel fixups: PASS');
