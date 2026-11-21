// Loop heads, update, compound and logical assignment write a block binding of global code in
// its register, refuse a const without changing it, and throw in the dead zone. The function
// cases are the same `const` refusals for register-resident locals.
{
    const log = [];
    let k = 'none', v = 'none', n = 1, s = null, t = 0, cnt = 0;
    for (k in { a: 1, b: 2 }) cnt++;
    for (v of [7, 8]) cnt++;
    for ([n, t] of [[3, 4]]) cnt++;
    n++; ++n; n--; n += 10; n **= 2; n ||= 0; s ??= 'S'; t &&= 5;
    log.push(k, v, n, s, t, cnt, typeof k);
    {
        let bk, bv, bn = 1, bs, cnt2 = 0;
        for (bk in { x: 1 }) cnt2++;
        for (bv of 'pq') cnt2++;
        for ({ bn } of [{ bn: 6 }]) cnt2++;
        bn += 1; bs ??= 'B'; bs &&= bs + '!';
        log.push(bk, bv, bn, bs, cnt2);
    }
    try { for (late in { z: 1 }); } catch (e) { log.push(e.constructor.name); }
    try { for (late of [1]); } catch (e) { log.push(e.constructor.name); }
    try { late++; } catch (e) { log.push(e.constructor.name); }
    try { late ??= 1; } catch (e) { log.push(e.constructor.name); }
    let late = 0;
    const c = 1;
    try { for (c of [2]); } catch (e) { log.push(e.constructor.name, c); }
    try { c += 1; } catch (e) { log.push(e.constructor.name, c); }
    try { c ||= 3; log.push('noop', c); } catch (e) { log.push(e.constructor.name, c); }
    if (log.join(' ') !== 'b 8 196 S 5 5 string x q 7 B! 4 ReferenceError ReferenceError ReferenceError ReferenceError TypeError 1 TypeError 1 noop 1') throw new Error('FAIL: assignment targets: ' + log.join(' '));
}
function f() { const c = 1; try { for (c of [2]); return 'none ' + c; } catch (e) { return e.constructor.name + ' ' + c; } }
function g() { const c = 1; try { for (c in {z: 1}); return 'none ' + c; } catch (e) { return e.constructor.name + ' ' + c; } }
function h() { const c = 1; try { [c] = [2]; return 'none ' + c; } catch (e) { return e.constructor.name + ' ' + c; } }
if ([f(), g(), h()].join() !== 'TypeError 1,TypeError 1,TypeError 1') throw new Error('FAIL: const loop targets: ' + [f(), g(), h()].join());
print('loop_target_bindings: ok');
