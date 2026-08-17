// error.stack carries a per-frame source location: every "    at <name>"
// line appends "(<file>:<line>)". The innermost frame is the interesting one:
// its line comes from the throw site reached through the Error constructor, a
// builtin dispatch rather than a compiled-function call, so it exercises the
// caller-resume-point fix in the VM's call dispatcher.

var failures = 0;
function fail(msg) { failures++; print('FAIL: ' + msg); }

function inner() { throw new Error('boom'); }
function middle() { inner(); }
function outer() { middle(); }

var caught = null;
try { outer(); } catch (e) { caught = e; }
if (caught === null) {
    fail('outer() did not throw');
} else {
    var stack = caught.stack;
    var frames = [];
    var lines = stack.split('\n');
    for (var i = 0; i < lines.length; i++) {
        if (/^\s+at\s+/.test(lines[i])) frames.push(lines[i]);
    }
    if (frames.length < 4) {
        fail('expected at least 4 frames, got ' + frames.length + ' (' + stack + ')');
    }
    // Innermost first: inner, middle, outer, then the top-level script frame.
    // A "(file)" suffix with no ":line" means the frame's line was missing,
    // which is exactly the stale-caller-PC bug this pins.
    var re = /at\s+\S+\s+\([^)]*\.js:\d+\)/;
    for (var j = 0; j < 4; j++) {
        if (!re.test(frames[j])) {
            fail('frame ' + j + ' missing "(file:line)": ' + frames[j]);
        }
    }
}

// A deep stack must not truncate the location suffixes either.
function deepRecurse(n) {
    if (n === 0) { throw new RangeError('deep'); }
    return deepRecurse(n - 1);
}
var deepCaught = null;
try { deepRecurse(50); } catch (e) { deepCaught = e; }
if (deepCaught !== null) {
    var deepLines = deepCaught.stack.split('\n');
    var located = 0;
    for (var k = 0; k < deepLines.length; k++) {
        if (/^\s+at\s+\S+\s+\([^)]*\.js:\d+\)/.test(deepLines[k])) located++;
    }
    if (located < 50) {
        fail('deep stack lost locations: only ' + located + ' frames carry (file:line)');
    }
}

if (failures === 0) {
    print('PASS: error.stack carries per-frame source locations');
}
