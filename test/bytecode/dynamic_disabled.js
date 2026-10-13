function check(value, message) { if (!value) throw new Error(message); }
for (var compile of [() => eval('42'), () => Function('return 42'), () => (function*(){}).constructor('yield 42'), () => (async function(){}).constructor('return 42')]) {
    var rejected = false;
    try { compile(); } catch (error) { rejected = error instanceof TypeError; }
    check(rejected, 'dynamic compilation');
}
print('dynamic compilation disabled');
