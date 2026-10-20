// Separate construction entry from the instance-property work it performs.
var N = 250000;
function Empty() {}
function One(a) { this.a=a; }
function Four(a,b,c,d) { this.a=a; this.b=b; this.c=c; this.d=d; }
function Eight(a,b,c,d,e,f,g,h) {
    this.a=a; this.b=b; this.c=c; this.d=d;
    this.e=e; this.f=f; this.g=g; this.h=h;
}
function makeEmpty() { return {}; }
function makeOne(a) { return {a:a}; }
function makeFour(a,b,c,d) { return {a:a,b:b,c:c,d:d}; }
function makeEight(a,b,c,d,e,f,g,h) {
    return {a:a,b:b,c:c,d:d,e:e,f:f,g:g,h:h};
}
function phase(name, run, want) {
    var start=Date.now(), got=run();
    print('PHASE '+name+' '+(Date.now()-start)+' '+got);
    if(got!==want) throw Error(name+': '+got+' != '+want);
}
phase('literal-empty', function(){
    for(var i=0;i<N;i++) makeEmpty();
    return N;
}, N);
phase('new-empty', function(){
    for(var i=0;i<N;i++) new Empty();
    return N;
}, N);
phase('new-one', function(){
    var s=0; for(var i=0;i<N;i++) s+=new One(i).a; return s;
}, N*(N-1)/2);
phase('factory-one', function(){
    var s=0; for(var i=0;i<N;i++) s+=makeOne(i).a; return s;
}, N*(N-1)/2);
phase('new-four', function(){
    var s=0; for(var i=0;i<N;i++) {var o=new Four(i,i+1,i+2,i+3); s+=o.a+o.b+o.c+o.d;} return s;
}, 2*N*(N-1)+6*N);
phase('factory-four', function(){
    var s=0; for(var i=0;i<N;i++) {var o=makeFour(i,i+1,i+2,i+3); s+=o.a+o.b+o.c+o.d;} return s;
}, 2*N*(N-1)+6*N);
phase('new-eight', function(){
    var s=0; for(var i=0;i<N;i++) {var o=new Eight(i,i+1,i+2,i+3,i+4,i+5,i+6,i+7); s+=o.a+o.b+o.c+o.d+o.e+o.f+o.g+o.h;} return s;
}, 4*N*(N-1)+28*N);
phase('factory-eight', function(){
    var s=0; for(var i=0;i<N;i++) {var o=makeEight(i,i+1,i+2,i+3,i+4,i+5,i+6,i+7); s+=o.a+o.b+o.c+o.d+o.e+o.f+o.g+o.h;} return s;
}, 4*N*(N-1)+28*N);
phase('new-four-assign-after', function(){
    var s=0; for(var i=0;i<N;i++) {var o=new Empty(); o.a=i;o.b=i+1;o.c=i+2;o.d=i+3; s+=o.a+o.b+o.c+o.d;} return s;
}, 2*N*(N-1)+6*N);
print('CHECK constructors '+N);
