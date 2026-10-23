// Keep known literal layouts across their small-object allocation boundaries.
function make(n, i) {
    switch (n) {
    case 0: return {};
    case 1: return {a:i};
    case 2: return {a:i,b:1};
    case 4: return {a:i,b:1,c:2,d:3};
    case 5: return {a:i,b:1,c:2,d:3,e:4};
    case 6: return {a:i,b:1,c:2,d:3,e:4,f:5};
    case 8: return {a:i,b:1,c:2,d:3,e:4,f:5,g:6,h:7};
    case 9: return {a:i,b:1,c:2,d:3,e:4,f:5,g:6,h:7,j:8};
    default: return {a:i,b:1,c:2,d:3,e:4,f:5,g:6,h:7,j:8,k:9,l:10,m:11,n:12,o:13,p:14,q:15};
    }
}
var counts = [0,1,2,4,5,6,8,9,16];
var total = 0;
for (var c = 0; c < counts.length; c++) {
    var kept = [];
    for (var i = 0; i < 5000; i++) {
        var obj = make(counts[c], i);
        if (Object.keys(obj).length !== counts[c]) throw new Error('field count');
        obj[0] = i;
        obj.extra = i;
        for (var k = 0; k < 20; k++) obj['extra' + k] = k;
        delete obj.b;
        Object.freeze(obj);
        if (obj[0] !== i || obj.extra !== i || obj.extra19 !== 19) throw new Error('growth');
        kept.push(obj);
    }
    for (var i = 0; i < kept.length; i++) total += kept[i].extra;
}
if (total !== 112477500) throw new Error('retained values');
print('PASS ' + total);
