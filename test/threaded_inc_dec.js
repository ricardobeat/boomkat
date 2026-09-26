function check(ok) { if (!ok) throw new Error('threaded INC/DEC'); }
function up(x) { x++; return x; }
function down(x) { x--; return x; }
check(up(0)===1 && down(0)===-1);
check(up(-7)===-6 && down(7)===6);
check(up(140737488355325)===140737488355326);
check(down(-140737488355326)===-140737488355327);
check(up(1.5)===2.5 && down(1.5)===0.5);
check(up(Infinity)===Infinity && down(-Infinity)===-Infinity);
check(isNaN(up(NaN)));
check(up('41')===42 && down('41')===40);
check(up(2n)===3n && down(2n)===1n);
var calls=0;
check(up({valueOf:function(){calls++;return 7;}})===8 && calls===1);
var thrown={};try{down({valueOf:function(){throw thrown;}});check(false);}catch(e){check(e===thrown);}
try{up(Symbol());check(false);}catch(e){check(e instanceof TypeError);}
var sum=0;for(var i=0;i<100000;i++)sum+=i;
for(var j=100000;j>0;j--)sum-=j-1;
check(sum===0);
function recurse(n){if(n===0)return 1;return recurse(n-1)+1;}
var coerce={valueOf:function(){return recurse(200);}};check(up(coerce)===202);
print('PASS threaded INC/DEC');
