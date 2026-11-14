var f = new Function('class A { #x = 41; #m() { return 1; } get #g() { return 0; } read() { return eval("this.#x + this.#m() + this.#g"); } } return new A();');
var a = f();
var junk = []; for (var i = 0; i < 2000; i++) junk.push(new Function('return "pad' + i + '" + ' + i));
if (a.read() !== 42) throw new Error('eval lost the private names');
print('eval private names after compile: OK');
