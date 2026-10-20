var N = 1200;
var sparse = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
var dense = 'a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,a,ax';
var absent = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
var checksum = 0;
var started;

started = Date.now();
for (var i = 0; i < N; i++) {
    var sparseParts = sparse.split(/,/);
    if (sparseParts.length === 2) checksum++;
}
print('PHASE split_sparse ' + (Date.now() - started));

started = Date.now();
for (var j = 0; j < N; j++) {
    var denseParts = dense.split(/,/);
    if (denseParts.length === 32) checksum++;
}
print('PHASE split_dense ' + (Date.now() - started));

started = Date.now();
for (var k = 0; k < N; k++) {
    var absentParts = absent.split(/,/);
    if (absentParts.length === 1) checksum++;
}
print('PHASE split_absent ' + (Date.now() - started));
print('CHECK ' + checksum);
