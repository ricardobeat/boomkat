// arr_has_prop's `vm` parameter defaults to null, and for a Proxy receiver
// it unconditionally returns false when vm is null (it needs vm to invoke
// the proxy's "has" trap). Many Array.prototype methods called
// arr_has_prop(obj, i, ctx.heap) without passing ctx.vm, so EVERY index of a
// Proxy-wrapped array was reported as absent -- forEach/map/filter/every/
// some/reduce/reduceRight/concat/sort all silently treated a Proxy array as
// if every element were a hole.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

var proxy = new Proxy([1, 2, 3], {});

// --- forEach ---
{
    var calls = 0;
    proxy.forEach(() => calls++);
    check("forEach visits a Proxy array's elements", calls, 3);
}

// --- map ---
{
    var mapped = proxy.map((x) => x * 2);
    check("map visits a Proxy array's elements", mapped.join(","), "2,4,6");
}

// --- filter ---
{
    var filtered = proxy.filter((x) => x > 1);
    check("filter visits a Proxy array's elements", filtered.join(","), "2,3");
}

// --- every ---
{
    check("every visits a Proxy array's elements", proxy.every((x) => x > 0), true);
}

// --- some ---
{
    check("some visits a Proxy array's elements", proxy.some((x) => x === 2), true);
}

// --- reduce ---
{
    check("reduce visits a Proxy array's elements", proxy.reduce((a, b) => a + b, 0), 6);
}

// --- reduceRight ---
{
    check("reduceRight visits a Proxy array's elements", proxy.reduceRight((a, b) => a + "," + b), "3,2,1");
}

// --- concat ---
{
    check("concat spreads a Proxy array's elements", [0].concat(proxy).join(","), "0,1,2,3");
}

// --- sort: present/hole distinction on a Proxy must be observed correctly ---
{
    var deleted = [];
    var sparseProxy = new Proxy([, , 0], {
        deleteProperty(t, pk) { deleted.push(pk); return delete t[pk]; },
    });
    sparseProxy.sort();
    check("sort deletes exactly the holes on a Proxy array", deleted.join(","), "1,2");
    check("sort moves the one present element to index 0", sparseProxy[0], 0);
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
