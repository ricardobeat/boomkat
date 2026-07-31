// Closure/Value capture
// Tests closures capturing values from outer scope.

function makeAdders(n) {
    var adders = [];
    for (var i = 0; i < n; i++) {
        adders.push((function(x) {
            return function(v) { return v + x; };
        })(i));
    }
    return adders;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

var adders = makeAdders(5);
assert(adders.length === 5, "5 adders created");
assert(adders[0](10) === 10, "adders[0](10)=10, got " + adders[0](10));
assert(adders[1](10) === 11, "adders[1](10)=11, got " + adders[1](10));
assert(adders[4](10) === 14, "adders[4](10)=14, got " + adders[4](10));

function makeCounter() {
    var count = 0;
    return {
        increment: function() { count++; return count; },
        getCount: function() { return count; }
    };
}

var c = makeCounter();
assert(c.getCount() === 0, "initial count 0");
c.increment();
c.increment();
assert(c.getCount() === 2, "count after 2 increments = 2");
assert(c.increment() === 3, "increment returns 3");

var c2 = makeCounter();
assert(c2.getCount() === 0, "new counter independent");

print("engine/closures: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
