// Full-body SSA must derive fresh element storage after a collecting callback.
function scalableMemoryCallback(a, n, callback) {
  var sum = 0;
  for (var i = 0; i < n; i++) {
    var before = a[i];
    callback(a, i);
    sum += before + a[i];
    a[i] = a[i] + 1;
  }
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  sum += n & 1;
  return sum;
}
function growAndChange(a, i) {
  // Adding named properties moves inline dense storage into a new allocation.
  a.side = {i: i, text: 'retained-' + i};
  a[i] += 10;
}
for (var memoryRound = 0; memoryRound < 160; memoryRound++) {
  var memoryArray = [1, 2, 3, 4];
  if (scalableMemoryCallback(memoryArray, 4, growAndChange) !== 60 || memoryArray[0] !== 12 || memoryArray[3] !== 15)
    throw 'storage after callback';
}
var memoryThrowCalls = 0, memoryThrowArray = [1, 2, 3, 4];
try {
  scalableMemoryCallback(memoryThrowArray, 4, function (a, i) {
    memoryThrowCalls++;
    if (i === 2) throw 'memory stop';
    growAndChange(a, i);
  });
  throw 'missing memory throw';
} catch (e) { if (e !== 'memory stop') throw e; }
if (memoryThrowCalls !== 3 || memoryThrowArray[0] !== 12 || memoryThrowArray[1] !== 13 || memoryThrowArray[2] !== 3)
  throw 'replayed memory effect';
var holeArray = [1, 2, 3, 4], holeCalls = 0;
var holeSum = scalableMemoryCallback(holeArray, 4, function (a, i) { holeCalls++; delete a[i]; });
if (!isNaN(holeSum) || holeCalls !== 4 || !isNaN(holeArray[3])) throw 'hole after callback';
console.log('scalable SSA memory callbacks: PASS');
