// A compound SSA call may fold an own numeric property reached through a
// global binding. Every write or layout change must make the next call use
// the current value, including after a prior native entry has warmed up.
var dependencyDirection = {FORWARD: 1};
function DependencyConstraint(a, b) { this.direction = 1; this.a = a; this.b = b; }
DependencyConstraint.prototype.input = function () {
  return this.direction === dependencyDirection.FORWARD ? this.a : this.b;
};
DependencyConstraint.prototype.output = function () {
  return this.direction === dependencyDirection.FORWARD ? this.b : this.a;
};
DependencyConstraint.prototype.execute = function () { this.output().value = this.input().value; };
var dependencyA = {value: 0}, dependencyB = {value: 0};
var dependencyOwner = new DependencyConstraint(dependencyA, dependencyB);
function dependencyRun(c) { c.execute(); }
for (var i = 0; i < 500; i++) {
  dependencyOwner.input(); dependencyOwner.output();
  dependencyA.value = i; dependencyRun(dependencyOwner);
  if (dependencyB.value !== i) throw Error('dependency warmup');
}
dependencyDirection.FORWARD = -1;
dependencyA.value = 1; dependencyB.value = 17; dependencyRun(dependencyOwner);
if (dependencyA.value !== 17) throw Error('dependency slot write');
dependencyDirection = {FORWARD: 1};
dependencyA.value = 29; dependencyB.value = 0; dependencyRun(dependencyOwner);
if (dependencyB.value !== 29) throw Error('dependency binding write');
Object.defineProperty(dependencyDirection, 'FORWARD', {get: function () { return -1; }, configurable: true});
dependencyA.value = 0; dependencyB.value = 43; dependencyRun(dependencyOwner);
if (dependencyA.value !== 43) throw Error('dependency accessor transition');
print('SSA global dependency: PASS');
