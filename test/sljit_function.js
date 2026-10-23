(function () {
    function check(ok, message) { if (!ok) throw new Error(message); }
    const chunk = new Uint8Array(16);
    class Sink {
        constructor() { this.closed = false; this.size = 0; this.parts = []; this.nudge = null; }
        enqueue(value) { this.parts.push(value); this.size += value.length; }
        close() { if (this.closed) throw new TypeError('closed'); this.closed = true; this._wake(); }
        _wake() { if (this.nudge === null) return; const n = this.nudge; this.nudge = null; n(); }
    }
    function make(value, seed) {
        let n = seed;
        return {
            pull(c) { if (n++ === 8) c.close(); else c.enqueue(value); },
            count() { return n; }
        };
    }
    for (let request = 0; request < 1000; request++) {
        const source = make(chunk, 0), sink = new Sink();
        for (let i = 0; i < 9; i++) source.pull(sink);
        check(source.count() === 9 && sink.closed && sink.size === 128 && sink.parts.length === 8, 'fresh closure');
    }
    const oldEnqueue = Sink.prototype.enqueue;
    let invoked = 0;
    Sink.prototype.enqueue = function (value) { invoked++; return oldEnqueue.call(this, value); };
    let source = make(chunk, 0), sink = new Sink();
    for (let i = 0; i < 9; i++) source.pull(sink);
    check(invoked === 8 && source.count() === 9 && sink.closed, 'replaced method');
    let getters = 0;
    Object.defineProperty(Sink.prototype, 'enqueue', {configurable: true, get() { getters++; return oldEnqueue; }});
    source = make(chunk, 0); sink = new Sink();
    for (let i = 0; i < 9; i++) source.pull(sink);
    check(getters === 8 && source.count() === 9 && sink.size === 128, 'accessor executes once');
    Object.defineProperty(Sink.prototype, 'enqueue', {value: oldEnqueue, writable: true, configurable: true});
    for (const seed of ['0', false, 0.0]) {
        source = make(chunk, seed); sink = new Sink();
        for (let i = 0; i < 9; i++) source.pull(sink);
        check(source.count() === 9 && sink.closed && sink.size === 128, 'counter coercion');
    }
    source = make(chunk, 140737488355326); sink = new Sink();
    for (let i = 0; i < 5; i++) source.pull(sink);
    check(source.count() === 140737488355331 && sink.size === 80, 'counter overflow');
    let thrown = 0;
    const throwing = {enqueue() { throw new Error('enqueue'); }, close() {}};
    source = make(chunk, 0);
    try { source.pull(throwing); } catch (error) { thrown++; }
    check(thrown === 1 && source.count() === 1, 'throw preserves increment');
    let outer;
    const reentrant = {enqueue() { outer.pull({enqueue() {}, close() {}}); }, close() {}};
    outer = make(chunk, 0); outer.pull(reentrant);
    check(outer.count() === 2, 'reentrant capture');

    function select(record) {
        const left = record.left, right = record.right;
        return record.pick ? left : right;
    }
    let retained;
    for (let i = 0; i < 1000; i++) {
        const record = {left: 'left-' + i, right: 'right-' + i, pick: (i & 1) === 0};
        retained = select(record);
        check(retained === (record.pick ? record.left : record.right), 'string register ownership');
    }
    check(retained === 'right-999', 'returned string survives frame');
    function compute(record) { const a = record.left, b = record.right; return a + b + record.left + record.right; }
    const record = {left: 10, right: 20};
    for (let i = 0; i < 200; i++) check(compute(record) === 60, 'numeric fields');
    Object.defineProperty(record, 'left', {configurable: true, get() { getters++; return 40; }});
    const before = getters;
    check(compute(record) === 120 && getters === before + 2, 'shape invalidation');
    Object.defineProperty(record, 'left', {value: 50, writable: false, configurable: true});
    for (let i = 0; i < 200; i++) check(compute(record) === 140, 'new shape');
    const proto = {left: 1, right: 2};
    for (let i = 0; i < 200; i++) check(compute(Object.create(proto)) === 6, 'prototype data');
    Object.defineProperty(proto, 'right', {configurable: true, get() { getters++; return 4; }});
    check(compute(Object.create(proto)) === 10, 'prototype descriptor change');
    let reads = 0;
    const proxied = new Proxy({left: 2, right: 3}, {get(target, key) { reads++; return target[key]; }});
    check(compute(proxied) === 10 && reads === 4, 'proxy fallback');
    function setFields(receiver, value) { receiver.value = value; receiver.ready = true; return receiver.value; }
    for (let i = 0; i < 200; i++) check(setFields({value: 0, ready: false}, i) === i, 'field stores');
    const frozen = Object.freeze({value: 4, ready: false});
    check(setFields(frozen, 8) === 4 && frozen.ready === false, 'sloppy frozen store');
    function strictStore(receiver, value) { 'use strict'; receiver.value = value; receiver.ready = true; return receiver.value; }
    for (let i = 0; i < 200; i++) check(strictStore({value: 0, ready: false}, i) === i, 'strict field stores');
    thrown = 0; try { strictStore(frozen, 8); } catch (error) { if (error instanceof TypeError) thrown++; }
    check(thrown === 1, 'strict frozen store');
    function hasTypes(record, value) {
        const expected = record.expected;
        return typeof value === expected && typeof record.other === expected;
    }
    for (const value of [1, {}, true, undefined, null, function () {}, 'text', 1n]) {
        const typed = {expected: typeof value, other: value};
        for (let i = 0; i < 200; i++) check(hasTypes(typed, value), 'typeof reads its source register');
        check(!hasTypes({expected: 'wrong', other: value}, value), 'typeof mismatch');
    }
    function responseStatus(init) {
        const status = init.status === undefined ? 200 : init.status | 0;
        if (status < init.lower || status > init.upper) throw new RangeError('status');
        init.observed = status;
        return status;
    }
    const statusInit = {status: 200, lower: 200, upper: 599, observed: 0};
    for (let i = 0; i < 300; i++) {
        statusInit.status = (i & 1) ? 503 : undefined;
        check(responseStatus(statusInit) === ((i & 1) ? 503 : 200), 'range comparison after interpreter exit');
    }
    for (const status of [199, 600, -1]) {
        statusInit.status = status; thrown = 0;
        try { responseStatus(statusInit); } catch (error) { if (error instanceof RangeError) thrown++; }
        check(thrown === 1, 'range comparison rejects invalid status');
    }
    function bounds(record) { return record.left <= record.right && record.right >= record.left; }
    for (let i = 0; i < 200; i++) check(bounds({left: -2, right: 3}), 'inclusive comparisons');
    check(!bounds({left: 4, right: 3}) && bounds({left: 3.5, right: 3.5}) && !bounds({left: NaN, right: 3}), 'numeric comparison fallbacks');
    function serverPump(source, sink) {
        if (sink.failed) return {
            a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8, i: 9, j: 10,
            k: 11, l: 12, m: 13, n: 14, o: 15, p: 16, q: 17, r: 18, s: 19, t: 20
        };
        const before = sink.size + sink.count + sink.first + sink.last;
        source.pull(sink);
        const after = sink.size + sink.count + sink.first + sink.last;
        return after - before;
    }
    const pumpSink = {failed: false, size: 0, count: 0, first: 0, last: 0};
    const pumpSource = {pull(sink) { sink.size += 3; sink.count++; }};
    for (let i = 0; i < 200; i++) check(serverPump(pumpSource, pumpSink) === 4, 'native call continuation');
    let finalized = 0;
    const finalizing = {pull(sink) { sink.size += 7; sink.count++; }};
    try { check(serverPump(finalizing, pumpSink) === 8, 'changed callee'); }
    finally { finalized++; }
    check(finalized === 1, 'finally after native continuation');
    const failing = {pull() { throw new Error('pull'); }};
    thrown = 0;
    try { serverPump(failing, pumpSink); } catch (error) { thrown++; }
    check(thrown === 1, 'throw bypasses native continuation');
    pumpSink.failed = true;
    check(serverPump(pumpSource, pumpSink).t === 20, 'cold allocation exit');
    pumpSink.failed = false;
    globalThis.jitFunctionPump = serverPump;
    globalThis.jitFunctionSource = pumpSource;
    globalThis.jitFunctionSink = pumpSink;
    globalThis.jitFunctionWork = function functionFields(value) { return value.left + value.right + value.left + value.right; };
    globalThis.jitFunctionRecord = {left: 4, right: 5};
    console.log('SLJIT functions: PASS');
})();
