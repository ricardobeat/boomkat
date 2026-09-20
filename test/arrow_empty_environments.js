var passed = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        throw new Error(name + ": expected " + expected + ", got " + actual);
    }
    passed++;
}

check("constant expression", (() => 42)(), 42);

function outerValue() {
    var value = 17;
    var read = () => value;
    var total = 0;
    for (var i = 0; i < 100; i++) total += read();
    return total;
}
check("repeated parent binding reads", outerValue(), 1700);

function nestedCapture() {
    var value = 23;
    return (() => (() => value))()();
}
check("nested closure uses parent chain", nestedCapture(), 23);

var receiver = {
    value: 31,
    read: function () {
        var arrow = () => this.value;
        return arrow.call({ value: 0 });
    }
};
check("lexical this", receiver.read(), 31);

function enclosingArguments(value) {
    return (() => arguments[0])();
}
check("lexical arguments", enclosingArguments(37), 37);

function NewTarget() {
    return (() => new.target)();
}
check("lexical new.target", new NewTarget(), NewTarget);
check("plain-call new.target", NewTarget(), undefined);

function bindingCases() {
    var outer = 5;
    var withVar = () => { var outer = 7; return outer; };
    var withLexical = () => { let outer = 11; return outer; };
    var withParam = value => value;
    return withVar() + withLexical() + withParam(13) + outer;
}
check("own bindings retain their scope", bindingCases(), 36);

function evalCase() {
    var value = 41;
    return (() => eval("value"))();
}
check("direct eval retains lexical scope", evalCase(), 41);

function tdzCase() {
    var value = 19;
    try {
        (() => { let value = value; })();
    } catch (e) {
        return e instanceof ReferenceError;
    }
    return false;
}
check("TDZ binding retains its scope", tdzCase(), true);

print("arrow_empty_environments: " + passed + " passed");
