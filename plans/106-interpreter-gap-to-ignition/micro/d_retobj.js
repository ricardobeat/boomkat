var N=20000000;
function C(){this.v=1;this.n=null;} C.prototype.e=function(){ return this.n; }; function run(){ var o=new C(); o.n=o; var s=0; for (var i=0;i<N;i++) { var t=o.e(); s=(s+t.v)|0; } return s; } run();
