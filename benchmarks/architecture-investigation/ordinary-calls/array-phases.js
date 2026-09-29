// Split the repository's array workload so a follow-up targets its hot phase.
var N = 250000;
var values = [];
var elapsed;
var start = Date.now();
for (var i = 0; i < N; i++) values.push(i);
elapsed = Date.now() - start;
print('PHASE push ' + elapsed);

var sum = 0;
start = Date.now();
for (var j = 0; j < N; j++) sum += values[j];
elapsed = Date.now() - start;
print('PHASE read ' + elapsed);

start = Date.now();
for (var k = 0; k < N; k++) values.pop();
elapsed = Date.now() - start;
print('PHASE pop ' + elapsed);

var indexed = [];
start = Date.now();
for (var m = 0; m < N; m++) indexed[m] = m * 2;
elapsed = Date.now() - start;
print('PHASE write ' + elapsed);

if (sum !== N * (N - 1) / 2 || indexed[N - 1] !== (N - 1) * 2) {
    throw new Error('array phase checksum');
}
