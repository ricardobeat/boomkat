// A binding shadowed by a nested scope of the same function (a block, loop head, switch, catch or
// block function) keeps one home for every access, before and after the inner scope; reads in
// the inner binding's dead zone throw instead of seeing the outer value.
function f() { let x = 1; x = 2; for (let x of [0]) {} return x; }
function g() { let x = 1; for (let i = 0; i < 3; i++) { x++; for (const x of [0]) {} } return x; }
function h() { let x = 1; x = 2; for (let x in { a: 1 }) {} return x; }
function k() { let x = 1; x = 5; switch (0) { case 0: let x = 3; } return x; }
function m() { let x = 1; x = 5; { let x = 3; } return x; }
function a() { let x = 1; { try { x; return 'no'; } catch (e) { return e.name; } let x = 2; } }
function b() { let x = 1; { try { x = 3; return 'no'; } catch (e) { return e.name; } let x = 2; } }
function c() { let x = 1; switch (0) { case 0: try { x; return 'no'; } catch (e) { return e.name; } let x = 2; } }
function d() { let x = 1; { try { return typeof x; } catch (e) { return e.name; } class x {} } }
function e() { let x = 1; try { for (let [x] of [[x]]) {} return 'no'; } catch (er) { return er.name; } }
function g2() { let x = 1; try { for (let x of [x]) {} return 'no'; } catch (er) { return er.name; } }
function t() { var f = 1; f = 2; { function f() {} } return typeof f; }
function u(x) { x = 4; { let x = 1; } return x; }
function v() { try { throw 1; } catch (e) { e = 2; try { throw 3; } catch (e) {} return e; } }
function loop() { var count = 0; for (let x = 0; x < 10;) { x++; count++; { let x = 'hello'; continue; } } return count; }
const got = [f(), g(), h(), k(), m(), a(), b(), c(), d(), e(), g2(), t(), u(0), v(), loop()].join();
const want = '2,4,2,5,5,ReferenceError,ReferenceError,ReferenceError,ReferenceError,ReferenceError,ReferenceError,function,4,2,10';
if (got !== want) throw new Error('FAIL: ' + got);
print('shadowed_bindings: ok');
