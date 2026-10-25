var N=20000000;
function C(){this.v=1;} C.prototype.e=function(a){ return a; }; var o=new C(); function run(){ var s=0; for (var i=0;i<N;i++) { s=(s+o.e(i))|0; } return s; } run();
