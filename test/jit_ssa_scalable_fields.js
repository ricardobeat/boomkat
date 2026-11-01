// A full decoded body uses live SSA receivers for own numeric fields.
function scalableFields(o, n) {
  var sum = 0;
  for (var i = 0; i < n; i++) {
    o.x = o.x + 1;
    sum += o.x;
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
for (var fieldRound = 0; fieldRound < 160; fieldRound++) {
  var fields = {x: 1};
  if (scalableFields(fields, 8) !== 44 || fields.x !== 9) throw 'scalable fields';
}
// Numeric writes before an uncommon read remain committed exactly once.
var fieldGets = 0, fieldSets = 0, fieldValue = 1;
var accessors = {};
Object.defineProperty(accessors, 'x', {
  get: function () { fieldGets++; return fieldValue; },
  set: function (x) { fieldSets++; fieldValue = x; },
  configurable: true
});
if (scalableFields(accessors, 8) !== 44 || fieldGets !== 16 || fieldSets !== 8)
  throw 'scalable accessor recovery';
var fractionalFields = {x: 0.5};
if (scalableFields(fractionalFields, 8) !== 40 || fractionalFields.x !== 8.5)
  throw 'scalable fractional fields';
var readonlyFields = {x: 1};
Object.defineProperty(readonlyFields, 'x', {writable: false});
if (scalableFields(readonlyFields, 8) !== 8 || readonlyFields.x !== 1)
  throw 'scalable readonly recovery';
console.log('scalable SSA fields: PASS');
