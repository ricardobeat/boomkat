function check(value, message) { if (!value) throw new Error(message); }
check(this === undefined, 'module this');
var answer = await Promise.resolve(42);
check(answer === 42, 'top-level await');
async function run() { return await Promise.resolve(answer + 1); }
check(await run() === 43, 'async closure');
async function* values() { yield await Promise.resolve(20); yield 22; }
var total = 0;
for await (var value of values()) total += value;
check(total === 42, 'async generator');
try { await Promise.reject(new Error('expected')); } catch (error) { check(error.message === 'expected', 'await rejection'); }
print('bytecode async passed');
