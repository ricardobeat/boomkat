function t(n) {
  var s = 0, a = [], str = "hello, world", acc = "";
  for (var i = 0; i < n; i++) {
    a.push(i); a.push("x" + (i & 3)); a.push(i + 0.5);
    s += parseInt(i * 1.37) + parseInt(-i / 7) + parseInt(i) + parseInt(i * 1e-9) + parseInt(i * 1e17) + parseInt(-0.5 * (i & 1));
    s += (1 / parseInt(-0.25 * ((i & 1) + 1)) < 0 ? 1 : 0); s += (1 / Math.abs(-0) > 0 ? 1 : 0);
    s += Math.sin(i) + Math.cos(i / 3) + Math.abs(i - 50.5) + Math.sqrt(i) + Math.floor(i / 7) + Math.ceil(i / 7) + Math.round(i / 7 - 3)
       + Math.pow(i & 7, 2) + Math.atan2(i, 3) + Math.exp(i & 3) + Math.log(i + 1) + Math.tan(i) + Math.atan(i) + Math.max(i, 3.5) + Math.min(i, 7);
    acc = str.charAt(i % 14) + String.fromCharCode(65 + (i & 31)) + String.fromCharCode(i * 37) + str.charAt(-1) + String.fromCharCode(66, 67);
    s += acc.length + acc.charCodeAt(0) + (acc.charCodeAt(1) | 0);
    s += Math.sin("1") + (isNaN(Math.abs()) ? 2 : 0) + Math.abs(-0);
    if ((i & 1023) == 0) a = [];
  }
  return s + a.length + a.join("").length;
}
console.log(t(60000));
var frozen = Object.freeze([1]); var r = 0;
for (var i = 0; i < 3000; i++) { try { frozen.push(i); } catch (e) { r++; } }
console.log(r, frozen.length);
var holes = [1, , 3], o = { length: 2, push: Array.prototype.push }, sub = [];
for (var i = 0; i < 3000; i++) { o.push(i); if (i == 1500) Array.prototype[i * 2 + 5] = 1; sub.push(undefined); sub.push(i); }
console.log(o.length, sub.length, 3001 in sub);
var ca = "héllo".charAt, cc = String.fromCharCode, pi = parseInt, q = 0;
for (var i = 0; i < 3000; i++) { q += cc(104).length + pi("12px") + pi(15.9, 8) + pi("ff", 16) + "héllo".charAt(1).length + "😀".charAt(0).length; try { ca(0); } catch (e) { q++; } }
console.log(q, 1 / parseInt(-0), 1 / parseInt(-0.5), parseInt(1e21), parseInt(1e-7), parseInt(NaN), parseInt(Infinity), parseInt(9007199254740993), parseInt(4294967296.5), parseInt(-2147483648.9));
