function pair(a, b) { return a + ':' + b; }
function argumentRead(o) { return pair(o.value, o.value); }
function aliasRead(o) { o = o.next; return o.value; }
function chooseRead(o, choose) { var value = 9; if (choose) value = o.value; return value; }
var calls = 0;
var object = {get value() { return ++calls; }, next: {value: 17}};
for (var i = 0; i < 300; i++) {
    var before = calls;
    if (argumentRead(object) !== (before + 1) + ':' + (before + 2)) throw Error('argument order');
    if (aliasRead(object) !== 17) throw Error('receiver alias');
    if (chooseRead(object, false) !== 9) throw Error('branch');
}
function preserveOnThrow(o) { var value = 'old'; try { value = o.value; } catch (e) {} return value; }
if (preserveOnThrow({get value() { throw Error('expected'); }}) !== 'old') throw Error('throw destination');
var method = {value: 23, read: function () { var x = this.value; return pair(x, x); }};
for (var j = 0; j < 300; j++) if (method.read() !== '23:23') throw Error('this');
print('named read moves ok');
