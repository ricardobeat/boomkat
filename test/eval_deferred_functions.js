// Eval validates every body eagerly, but ordinary bodies may compile on first use.
function check(value) { if (!value) throw new Error('deferred eval function'); }
var source = '(function(a,b) { return function(c) { return a+b+c; }; })';
var make = (0, eval)(source);
check(make.length === 2 && make.name === '');
check(make.toString() === source.slice(1, -1));
var add = make(3, 4);
check(add(5) === 12 && [1, 2].map(add).join() === '8,9');

var accessors = (0, eval)(`(function() {
  var value = 2, object = {};
  Object.defineProperty(object, 'x', {
    get: function() { return value; },
    set: function(next) { value = next; }
  });
  object.x = 9;
  return object.x;
})`);
check(accessors() === 9);

var Constructor = (0, eval)('(function(x) { this.x = x; })');
check(new Constructor(13).x === 13);
var strict = (0, eval)('(function() { "use strict"; return this; })');
check(strict() === undefined);

// Free names keep the captured environment, including a top-level lexical block.
(0, eval)('{ let secret = 17; globalThis.deferredSecret = function() { return secret; }; }');
check(deferredSecret() === 17);
delete globalThis.deferredSecret;

// Invalid uncalled bodies must still throw at eval time.
var rejected = false;
try { (0, eval)('function neverCalled() { let x; let x; }'); }
catch (error) { rejected = error instanceof SyntaxError; }
check(rejected);

// The source and enclosing bindings outlive the eval call and later compilations.
var saved = (0, eval)('(function(x) { return function() { return x; }; })')(23);
for (var i = 0; i < 20; i++) (0, eval)('(function(x) { return x + 1; })')(i);
check(saved() === 23);
print('deferred eval functions: OK');
