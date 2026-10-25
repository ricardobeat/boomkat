var N=20000000;
function C(){this.v=1;} function run(){ var o=new C(); var s=0; for (var i=0;i<N;i++) { s=(s+o.v)|0; } return s; } run();
