"use strict";
// Builtin calls answered by leaf entries from generated code, in tail position
// and not: string results returned through native returns, builtins replaced
// at run time, arrays whose pop or push must take the full builtin, and a
// tail call that must still reuse the frame.
var out = [];

function Stream(bytes) { this.bytes = bytes; this.pos = 0; }
Stream.prototype.getChar = function () {
    if (this.pos >= this.bytes.length) return null;
    return String.fromCharCode(this.bytes[this.pos++]);
};
Stream.prototype.lookChar = function () { return this.bytes.length > this.pos ? String.fromCharCode(this.bytes[this.pos]) : null; };
function readAll(n) {
    var bytes = [];
    for (var i = 0; i < 64; i++) bytes.push(i % 3 === 0 ? 0x3b1 : 65 + (i % 26));
    var total = "", count = 0;
    for (var k = 0; k < n; k++) {
        var s = new Stream(bytes), ch, line = "";
        while ((ch = s.getChar()) !== null) { line += s.lookChar() === null ? "" : ch; count++; }
        if (k === n - 1) total = line;
    }
    return count + ":" + total.length + ":" + total.slice(0, 8);
}
out.push(readAll(300));

function charAt(s, i) { return s.charAt(i); }
function upper(s) { return s.toUpperCase(); }
function strings(n) {
    var acc = 0, last = "";
    for (var i = 0; i < n; i++) {
        var c = charAt("hello world", i % 13);
        last = upper(c) + c.toLowerCase() + "abc".substring(i % 4, 2) + "abcdef".slice(-(i % 5));
        acc += last.length + "hello".indexOf(c) + "a,b,c".lastIndexOf(",");
    }
    return acc + ":" + last;
}
out.push(strings(4000));

function swapped(n) {
    var t = 0;
    for (var i = 0; i < n; i++) {
        t += Math.abs(i - 2000) + Math.floor(i / 3) + Math.max(i, 7) + parseFloat("1." + (i % 10)) * 10;
        if (i === n / 2) Math.abs = function (x) { return -1; };
    }
    return t;
}
var abs = Math.abs;
out.push(swapped(4000));
Math.abs = abs;

function pops(n) {
    var r = [];
    for (var i = 0; i < n; i++) {
        var a = [1, 2, 3];
        if (i % 11 === 0) a.length = 5;
        if (i % 7 === 0) Object.freeze(a);
        try { r.push(a.pop()); } catch (e) { r.push(e.name); }
        if (i % 13 === 0) { var b = [1, , 3]; b.pop(); Array.prototype[1] = "p"; r.push(b.pop()); delete Array.prototype[1]; }
    }
    return r.slice(-20).join(",") + ":" + r.length;
}
out.push(pops(3000));

function count(n, acc) { return n === 0 ? acc : count(n - 1, acc + 1); }
out.push(count(200000, 0));

function retString(i) { var s = "k" + (i % 50); return s; }
function strings2(n) {
    var o = {}, t = 0;
    for (var i = 0; i < n; i++) { var k = retString(i); o[k] = i; t += k.length; }
    return t + ":" + Object.keys(o).length;
}
out.push(strings2(5000));

console.log(out.join(" "));
