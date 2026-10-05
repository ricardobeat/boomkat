function equal(actual, expected) {
    if (actual !== expected) throw new Error(String(actual) + " !== " + String(expected));
}
function optional() {
    var calls = 0;
    var object = {value: 1, method() { equal(this, object); calls++; return this.value; }};
    equal(object?.method?.(), 1);
    equal((object?.method)(), 1);
    equal(null?.method(++calls), undefined);
    equal(null?.[++calls], undefined);
    equal(calls, 2);
    equal(delete null?.value, true);
    var gets = 0;
    var getter = {get value() { gets++; return 2; }};
    equal(delete getter?.value, true);
    equal(gets, 0);
    var original = {value: 3}, base = original;
    equal(base?.[(base = {value: 4}, "value")], 3);
    equal(base.value, 4);
}
function tags() {
    var seen, object = {tag(parts, value) { equal(this, object); return value; }};
    var original = object;
    equal(object.tag`${(object = original, 5)}`, 5);
    var first = function (parts, value) { return value; }, tag = first;
    equal(tag`${(tag = function () { return 0; }, 6)}`, 6);
    var x = 7;
    function values(parts, a, b) { equal(a, 7); equal(b, 8); }
    values`${x}${x = 8}`;
    function site() { return first`raw\ntext`; }
    function cache(parts) {
        equal(Object.isFrozen(parts), true);
        equal(Object.isFrozen(parts.raw), true);
        if (seen) equal(parts, seen);
        seen = parts;
        equal(parts[0], "raw\ntext");
        equal(parts.raw[0], "raw\\ntext");
    }
    function cachedSite() { cache`raw\ntext`; }
    cachedSite(); cachedSite();
    function invalid(parts) { equal(parts[0], undefined); equal(parts.raw[0], "\\xZ"); }
    invalid`\xZ`;
}
optional();
tags();
