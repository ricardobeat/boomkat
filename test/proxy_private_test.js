class ProxyBase {
  constructor() {
    return new Proxy(this, {
      get: function (obj, prop) {
        arr.push(prop);
        return obj[prop];
      }
    });
  }
}
class Test extends ProxyBase {
  #f = 3;
  method() { return this.#f; }
}
let arr = [];
let t = new Test();
let r = t.method();
if (r !== 3) throw new Error("Expected 3, got " + r);
if (arr.length !== 1) throw new Error("Expected arr.length=1, got " + arr.length);
if (arr[0] !== 'method') throw new Error("Expected arr[0]='method', got " + arr[0]);
print("PASS");
