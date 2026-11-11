function t(n) { var s = 0; for (var i = 0; i < n; i++) { s += parseInt("12", 10) + (isNaN(i / 0 - i / 0) ? 1 : 0) + Number("3") + String(i).length; } return s; }
console.log(t(200000));
var isNaN2 = isNaN; isNaN = function (x) { return 7; };
function u(n) { var s = 0; for (var i = 0; i < n; i++) s += isNaN(i); return s; }
console.log(u(1000));
isNaN = isNaN2; console.log(u(1000));
try { (function () { for (var i = 0; i < 3000; i++) { if (i == 2999) parseInt = 5; parseInt("1"); } })(); } catch (e) { console.log(e instanceof TypeError); }
function th() { for (var i = 0; i < 3000; i++) { try { decodeURIComponent(i == 2500 ? "%" : "a"); } catch (e) { return e.name + i; } } }
console.log(th());
