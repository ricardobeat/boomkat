function Record(a,b,c,d,e,f) { this.a=a; this.b=b; this.c=c; this.d=d; this.e=e; this.f=f; }
var total = 0, keep = [];
for (var i = 0; i < 300000; i++) {
    var object = new Record(i,1,2,3,4,5);
    total += object.a + object.f;
    if (i % 1000 === 0) keep.push(object);
}
if (total !== 45001350000 || keep[10].a !== 10000) throw new Error('constructor');
print('PASS ' + total);
