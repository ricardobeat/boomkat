// An inherited read whose cache settled several receivers (its entry's and the retained ones,
// hobject::ICProtoSet), each compiled as constants under the prototype epoch: after the compile a
// prototype's method is replaced, a receiver's prototype is swapped, and an own property shadows
// the inherited one. Each must read what the language says.
function A() { this.v = 1; } A.prototype.get = function () { return this.v + 10; };
function B() { this.v = 2; } B.prototype.get = function () { return this.v + 20; };
function C() { this.v = 3; } C.prototype.get = function () { return this.v + 30; };
function D() { this.v = 4; } D.prototype.get = function () { return this.v + 40; };
var objs = [new A(), new B(), new C(), new D()];
function sum(list) {
  var t = 0;
  for (var i = 0; i < list.length; i++) t += list[i].get();
  return t;
}
function rounds(n) {
  var t = 0;
  for (var q = 0; q < n; q++) t += sum(objs);
  return t;
}
var out = [];
out.push(rounds(3000));
B.prototype.get = function () { return this.v * 100; };
out.push(rounds(3000));
Object.setPrototypeOf(objs[2], A.prototype);
out.push(rounds(3000));
objs[3].get = function () { return -1; };
out.push(rounds(3000));
delete objs[3].get;
D.prototype.get = function () { return 7; };
out.push(rounds(3000));
print(out.join(" "));
