import {source, array, replace} from './source.js';
function check(v) { if (!v) throw new Error('allocation projection'); }
let value;
{ const copy = {...source, tail: 1}; value = copy.a; }
check(value === 17);
replace({a: 23});
{ const copy = {...source, tail: 1}; value = copy.a; }
check(value === 23);
{ const copy = [...array, 4]; value = copy.length; }
check(value === 4);
check(({a: function(){}}).a.name === 'a');
const escaping = {...source};
export {escaping};
check(escaping.a === 23);
