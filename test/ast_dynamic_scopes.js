function check(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' !== ' + expected);
}
(function () {
    var x = 2;
    var object = {x: 7, method() { return this.x; }};
    with (object) {
        check(x, 7);
        check(method(), 7);
        var closure = () => x;
        x = 8;
    }
    check(closure(), 8);
    check(x, 2);
    check(eval('x = 3; x'), 3);
    var indirect = eval;
    check(indirect('typeof x'), 'undefined');
    check((0, eval)('typeof x'), 'undefined');
    check((true ? eval : null)('typeof x'), 'undefined');
    var callee = () => 'old';
    function replace() { callee = () => 'new'; }
    check(callee(replace()), 'old');
    check(callee(), 'new');
    check(x + ([x] = [9])[0], 12);
    check(x, 9);
    var first, second;
    for (var i = 0; i < 2; i++) {
        check(fn(), i);
        function fn() { return i; }
        if (i === 0) first = fn;
        else second = fn;
    }
    check(first !== second, true);
    check(fn, second);
    if (true) function conditional() { return 13; }
    check(conditional(), 13);
    switch (0) {
        case 0: check(later(), 14); break;
        case 1: function later() { return 14; }
    }
    check(later(), 14);
    {
        label: function labelled() { return 15; }
        check(labelled(), 15);
    }
    check(labelled(), 15);
    let protectedName = 16;
    { function protectedName() { return 17; } check(protectedName(), 17); }
    check(protectedName, 16);
})();
(function () {
    var x = 99, object = {};
    Object.defineProperty(object, 'x', {
        configurable: true,
        get() { delete object.x; return 5; }
    });
    with (object) { check(x++, 5); }
    check(object.x, 6);
    check(x, 99);
    Object.defineProperty(object, 'x', {
        configurable: true,
        get() { delete object.x; return 7n; }
    });
    with (object) { check(++x, 8n); }
    check(object.x, 8n);
    check(x, 99);
})();
// Captured names and with operations also reach WIDE register and constant operands.
var wideSource = 'var x = 99;';
for (var wi = 0; wi < 280; wi++) wideSource += 'var name' + wi + '=' + wi + ';';
wideSource += 'eval(""); var o = {x:0}; with(o){x ||= 4; x++; var x = 8;} '
    + 'x = 7; return o.x === 8 && x === 7 && name279 === 279;';
check(Function(wideSource)(), true);
(function () {
    var value = 0;
    function assign() { value ||= eval('var value = 3; 7'); return value; }
    check(assign(), 3);
    check(value, 7);
})();
print('ast_dynamic_scopes: PASS');
