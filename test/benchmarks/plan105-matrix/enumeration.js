function make(i) {
    return {z:i,a:1,b:2,c:3,d:4,e:5,f:6,g:7,h:8,j:9,k:10,l:11,m:12,n:13,o:14,p:15};
}
var a = make(1), b = make(2);
var total = 0;
for (var i = 0; i < 150000; i++) {
    var object = i % 2 ? a : b;
    var keys = Object.keys(object);
    var own = Reflect.ownKeys(object);
    var names = Object.getOwnPropertyNames(object);
    total += keys.length + own.length + names.length;
    if (keys[0] !== 'z' || own[15] !== 'p' || names[1] !== 'a') throw new Error('ordering');
    keys[0] = 'changed';
}
if (total !== 7200000) throw new Error('enumeration');
print('PASS ' + total);
