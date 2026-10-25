var P = (typeof print != "undefined") ? print : console.log;
var now = (typeof performance != "undefined") ? function(){return performance.now();} : Date.now;
function bench(name, n, f) { f(1000); var t = now(); var r = f(n); var dt = now() - t; P(name + " " + (dt * 1e6 / n).toFixed(2) + " ns/iter " + r); }
