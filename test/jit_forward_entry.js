function Base() {}
Base.prototype.initialize = function (a, b, c) { this.s = (a | 0) + (b | 0) + (c | 0) + arguments.length; };
function K() { this.initialize.apply(this, arguments); }
K.prototype = Base.prototype;
function W(x) { return inner.apply(this, arguments); }
function inner() { var t = 0; for (var i = 0; i < arguments.length; i++) t += arguments[i]; return t; }
function run(n) {
  var t = 0;
  for (var i = 0; i < n; i++) {
    t += new K(i, 2, 3).s + new K().s + new K(1).s + W(1, 2, 3, 4, 5, 6, 7, 8, 9) + W() + W(i) + W(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11);
    t += W.call({ k: 1 }, i, i) + W("a").length;
  }
  return t;
}
console.log(run(200000));
