var key = Symbol.for("gc-nonwritable-key");
var base = {};
Object.defineProperty(base, key, { value: "cheese", writable: false });

function check(obj) {
    obj[key] = "portals";
    if (obj[key] !== "cheese") throw new Error("own or inherited write succeeded");
    try {
        (function () { "use strict"; obj[key] = "robots"; })();
        throw new Error("strict write did not throw");
    } catch (e) {
        if (!(e instanceof TypeError)) throw e;
    }
    if (obj[key] !== "cheese") throw new Error("read changed after strict write");
}

check(base);
var child = Object.create(base);
check(child);
check(Object.create(child));
