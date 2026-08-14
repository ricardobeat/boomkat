// This build's uuidv4() calls crypto.getRandomValues(), which the engine
// does not provide as a host API (it is a browser/node API, not a JS
// language feature) -- shim it deterministically so the check is
// reproducible rather than testing browser/host integration.
if (typeof crypto === "undefined") { globalThis.crypto = {}; }
if (typeof crypto.getRandomValues !== "function") {
    var seed = 1;
    crypto.getRandomValues = function (arr) {
        for (var i = 0; i < arr.length; i++) {
            seed = (seed * 1103515245 + 12345) & 0x7fffffff;
            arr[i] = seed & 0xff;
        }
        return arr;
    };
}

var uuidv4 = module.exports.default || module.exports;
var lines = [];
function rec(name, value) { lines.push(name + "=" + JSON.stringify(value)); }

var id = uuidv4();
rec("format", /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id));
rec("distinct", uuidv4() !== uuidv4());

console.log(lines.join("\n"));
console.log(lines.length + " uuid API checks recorded, 0 threw");
