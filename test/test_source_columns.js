// Stack coordinates use original-source lines and byte columns.
function checkFrame(stack, frame, line, column) {
    var actual = stack.split('\n')[frame + 1];
    var suffix = ':' + line + ':' + column + ')';
    if (!actual || actual.slice(-suffix.length) !== suffix) {
        throw new Error('Expected ' + suffix + ', got ' + actual);
    }
}

function leaf() {
    return new Error('leaf');
}
function multiline() {
    return [leaf(
        42
    )][0];
}
var error = multiline();
checkFrame(error.stack, 0, 11, 12);
checkFrame(error.stack, 1, 14, 13);

function sameLine(flag) { if (flag) return new Error('first'); return new Error('second'); }
checkFrame(sameLine(true).stack, 0, 22, 44);
checkFrame(sameLine(false).stack, 0, 22, 71);

function capturedVar() {
    var n = 0;
    n = 1;
    return [new Error('var'), function () { return n; }];
}
checkFrame(capturedVar()[0].stack, 0, 29, 13);
function capturedLet() {
    for (let n = 0; n < 1; n++) {
        return [new Error('let'), function () { return n; }];
    }
}
checkFrame(capturedLet()[0].stack, 0, 34, 17);

function propertyError() {
    var value = null;
    return value.missing;
}
try { propertyError(); } catch (e) {
    checkFrame(e.stack, 0, 41, 18);
}
function referenceError() {
    return missingSourcePositionName;
}
try { referenceError(); } catch (e) {
    checkFrame(e.stack, 0, 47, 12);
}

function unicode() { var text = 'é😀'; return new Error(text); }
checkFrame(unicode().stack, 0, 53, 50);
function* resumed() {
    yield 1;
    return new Error('resumed');
}
var generator = resumed();
generator.next();
checkFrame(generator.next().value.stack, 0, 57, 12);

print('PASS: stack source columns');
