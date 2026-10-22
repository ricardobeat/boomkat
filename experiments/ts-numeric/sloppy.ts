// Duplicate names are allowed in sloppy simple parameter lists after stripping.
function duplicate(a: number,a: number) { return a+a; }
if (duplicate('wrong',2)!==4) throw new Error('duplicate parameter fallback');
if (duplicate(1,3)!==6) throw new Error('duplicate parameter numeric');
function aliases(a: number,b: number) { arguments[0]='x'; return a+b; }
if (aliases(1,2)!=='x2') throw new Error('mapped arguments');
function strict(a: number,b: number) { 'use strict'; return a+b; }
if (strict('x',2)!=='x2'||strict(1,2)!==3) throw new Error('strict fallback');
const obj={method(a: number,b: number){return a*b+a;}};
if(obj.method(1.5,2.5)!==5.25)throw new Error('method numeric');
if(obj.method('2',3)!=='62')throw new Error('method fallback');
print('numeric-region sloppy/strict OK');
