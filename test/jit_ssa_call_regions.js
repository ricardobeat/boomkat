var regionDirection = {FORWARD: 1};
function RegionConstraint(a, b) { this.direction = 1; this.v1 = a; this.v2 = b; }
function regionInput() {
  return this.direction === regionDirection.FORWARD ? this.v1 : this.v2;
}
function regionOutput() {
  return this.direction == regionDirection.FORWARD ? this.v2 : this.v1;
}
RegionConstraint.prototype.input = regionInput;
RegionConstraint.prototype.output = regionOutput;
function regionExecute() { this.output().value = this.input().value; }
RegionConstraint.prototype.execute = regionExecute;
var regionA = {value: 0}, regionB = {value: 0};
var regionConstraint = new RegionConstraint(regionA, regionB);
for (var i = 0; i < 64; i++) {
  regionConstraint.input(); regionConstraint.output(); regionConstraint.execute();
}
// Exercise computed dispatch alongside the statically selected method calls.
// The embedding test separately requires a guarded native-entry completion.
function regionDrive(c, key, n) {
  var sum = 0;
  for (var i = 0; i < n; i++) {
    c.direction = (i & 1) ? 1 : -1;
    c.input().value = i;
    c[key]();
    if (c.output().value !== i) throw Error('SSA selector copy');
    sum += c.output().value;
  }
  return sum;
}
if (regionDrive(regionConstraint, 'execute', 2000) !== 1999000) throw Error('SSA region sum');
regionConstraint.direction = 1;
regionA.value = 'copied';
regionDrive(regionConstraint, 'execute', 0);
regionConstraint.execute();
if (regionB.value !== 'copied') throw Error('SSA string fallback');
var regionEffects = 0;
regionConstraint.input = function () { regionEffects++; return regionA; };
regionA.value = 9;
regionConstraint.execute();
if (regionEffects !== 1 || regionB.value !== 9) throw Error('SSA own method shadow');
delete regionConstraint.input;
var regionOriginal = RegionConstraint.prototype.input;
RegionConstraint.prototype.input = function () { regionEffects++; return regionA; };
regionConstraint.execute();
if (regionEffects !== 2) throw Error('SSA prototype method change');
RegionConstraint.prototype.input = regionOriginal;
Object.defineProperty(regionA, 'value', {get: function () { regionEffects++; return 17; }});
regionConstraint.execute();
if (regionEffects !== 3 || regionB.value !== 17) throw Error('SSA getter replay');
function regionChoose(n) { return n > 0 ? 1.25 : 2.5; }
function regionMissing(n) { var missing; return n + missing; }
var regionFunctions = {choose: regionChoose, missing: regionMissing};
function regionNumeric(o, key, n) { return o[key](n); }
for (var i = 0; i < 100; i++) regionNumeric(regionFunctions, 'choose', i);
var regionInputs = [1, -1, 0, 0.25, -0.25, NaN, Infinity, -Infinity];
for (var i = 0; i < regionInputs.length; i++) {
  var n = regionInputs[i];
  if (regionNumeric(regionFunctions, 'choose', n) !== (n > 0 ? 1.25 : 2.5)) throw Error('SSA select');
  if (!Number.isNaN(regionNumeric(regionFunctions, 'missing', n))) throw Error('SSA missing local');
}
print('SSA call regions: PASS');
