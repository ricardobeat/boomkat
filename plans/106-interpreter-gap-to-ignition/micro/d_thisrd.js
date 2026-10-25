var N=20000000;
function C(){this.v=1;} C.prototype.r=function(){ var s=0; for (var i=0;i<N;i++) { s=(s+this.v)|0; } return s; }; new C().r();
