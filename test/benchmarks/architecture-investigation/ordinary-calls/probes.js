// Matched arithmetic: distinguish property access, call entry, and allocation.
var N = 1000000;
function add(x) { return x + 1; }
function Point(x) { this.x = x; }
Point.prototype.add = function () { return this.x + 1; };
Object.defineProperty(Point.prototype, 'next', {get: function () { return this.x + 1; }});
var points = [];
for (var j = 0; j < 1024; j++) points.push(new Point(j));
function arithmetic() { var s=0; for(var i=0;i<N;i++) s+=(i&1023)+1; return s; }
function reads() { var s=0; for(var i=0;i<N;i++) s+=points[i&1023].x+1; return s; }
function calls() { var s=0; for(var i=0;i<N;i++) s+=add(i&1023); return s; }
function methods() { var s=0; for(var i=0;i<N;i++) s+=points[i&1023].add(); return s; }
function getters() { var s=0; for(var i=0;i<N;i++) s+=points[i&1023].next; return s; }
function literals() { var s=0; for(var i=0;i<N;i++) s+=({x:i&1023}).x+1; return s; }
function constructors() { var s=0; for(var i=0;i<N;i++) s+=new Point(i&1023).x+1; return s; }
function writesOne() { var p=points[0]; for(var i=0;i<N;i++) p.x=i; return p.x; }
function writesMany() { for(var i=0;i<N;i++) points[i&1023].x=i; return points[(N-1)&1023].x; }
var tests=[arithmetic,reads,calls,methods,getters,literals,constructors,writesOne,writesMany];
var names=['arithmetic','reads','calls','methods','getters','literals','constructors','writesOne','writesMany'];
for(var k=0;k<tests.length;k++) {
    var start=Date.now(), result=tests[k]();
    print('PHASE '+names[k]+' '+(Date.now()-start));
    if(result!==(k<7?512370976:999999)) throw Error('checksum '+names[k]+' '+result);
}
print('CHECK probes');
