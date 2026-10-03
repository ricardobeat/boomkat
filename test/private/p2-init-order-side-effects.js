// P2: field initializers run in source order, observable via side effects.
var log = [];
function track(tag, val) { log.push(tag); return val; }

class A {
    #a = track("a", 1);
    #b = track("b", 2);
    #c = track("c", 3);
    sum() { return this.#a + this.#b + this.#c; }
}

var a = new A();
if (a.sum() !== 6) throw new Error("expected sum 6, got " + a.sum());
var expected = "a,b,c";
var actual = log.join(",");
if (actual !== expected) throw new Error("expected order " + expected + ", got " + actual);

print("PASS");
