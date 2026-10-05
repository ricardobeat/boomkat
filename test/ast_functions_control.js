function check(value, expected) {
    if (value !== expected) throw new Error(value + ' !== ' + expected);
}

function closures(seed) {
    var value = seed;
    function read() { return value; }
    function bump() { return ++value; }
    return [read, bump, function recur(n) { return n ? n * recur(n - 1) : 1; }];
}
var a = closures(4), b = closures(20);
check(a[1](), 5);
check(a[0](), 5);
check(b[0](), 20);
check(a[2](5), 120);
check(a[2].name, 'recur');

function hoisted() {
    var result = later();
    function later() { return 1; }
    function later() { return 2; }
    return result;
}
check(hoisted(), 2);

function arrows(value) {
    var read = () => () => this.x + arguments[0];
    return read()();
}
check(arrows.call({x: 3}, 7), 10);
function names() {
    var arrow = x => x;
    var ordinary = function () {};
    var unnamed = (0, function () {});
    return [arrow.name, ordinary.name, unnamed.name].join(',');
}
check(names(), 'arrow,ordinary,');

function completion(flag) {
    var trace = '';
    outer: while (true) {
        try {
            if (flag) break outer;
            throw 3;
        } catch (error) {
            trace += error;
            break outer;
        } finally {
            trace += 'F';
        }
    }
    return trace;
}
check(completion(true), 'F');
check(completion(false), '3F');

function unwind() {
    var x = 7;
    while (true) {
        let x = 1;
        if (false) break;
        if (true) break;
    }
    return x;
}
check(unwind(), 7);

function choose(value) {
    var result = '';
    switch (value) {
        case 1: result += 'A';
        default: result += 'D';
        case 2: result += 'B'; break;
        case 3: result += 'C';
    }
    return result;
}
check(choose(1), 'ADB');
check(choose(9), 'DB');
check(choose(2), 'B');
check(choose(3), 'C');

function literals(value) { return `${/a+/.test(value)}:${1n + 2n}`; }
check(literals('aa'), 'true:3');
function Target() { return () => new.target; }
check(new Target()(), Target);
check(Target()(), undefined);
check(Function('return ' + Array(20000).fill('1').join('+'))(), 20000);
print('ast_functions_control: ok');
