// Test: ITER_CLOSE — .return() that throws propagates through catcher chain

function makeIter(returnFn) {
    var obj = {
        [Symbol.iterator]: function() { return obj; },
        next: function() { return { value: 1, done: false }; },
    };
    if (returnFn) obj['return'] = returnFn;
    return obj;
}

// Case 1: .return() throws — caught by surrounding try/catch
(function() {
    var thrown = null;
    try {
        for (var x of makeIter(function() { throw new Error("close-throw"); })) {
            break;
        }
    } catch (e) {
        thrown = e;
    }
    if (!(thrown instanceof Error) || thrown.message !== "close-throw") {
        throw new Error("Case 1 FAILED: expected Error('close-throw'), got: " + thrown);
    }
    print("Case 1 PASS: .return() throw caught in try/catch: " + thrown.message);
})();

// Case 2: .return() throws — inner catch handles it, outer does not see it
(function() {
    var innerCaught = null;
    var outerCaught = null;
    try {
        try {
            for (var x of makeIter(function() { throw new Error("inner-close-throw"); })) {
                break;
            }
        } catch (e) {
            innerCaught = e;
        }
    } catch (e) {
        outerCaught = e;
    }
    if (!(innerCaught instanceof Error) || innerCaught.message !== "inner-close-throw") {
        throw new Error("Case 2 FAILED: expected inner catch, got innerCaught=" + innerCaught + " outerCaught=" + outerCaught);
    }
    if (outerCaught !== null) {
        throw new Error("Case 2 FAILED: error leaked to outer catch");
    }
    print("Case 2 PASS: .return() throw caught in inner catch: " + innerCaught.message);
})();

// Case 3: no .return() method — clean break, no crash
(function() {
    try {
        for (var x of makeIter(null)) {
            break;
        }
    } catch (e) {
        throw new Error("Case 3 FAILED: unexpected throw: " + e);
    }
    print("Case 3 PASS: no .return() — clean break");
})();

// Case 4: .return() returns normally — no error, closed flag set
(function() {
    var closed = false;
    try {
        for (var x of makeIter(function() { closed = true; return { value: undefined, done: true }; })) {
            break;
        }
    } catch (e) {
        throw new Error("Case 4 FAILED: unexpected throw: " + e);
    }
    if (!closed) throw new Error("Case 4 FAILED: .return() not called");
    print("Case 4 PASS: .return() called and returned normally");
})();

print("ALL PASS");
