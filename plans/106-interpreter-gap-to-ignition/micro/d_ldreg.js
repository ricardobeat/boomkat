var N=20000000;
function run(){ var s=0, t=0; for (var i=0;i<N;i++) { t=i; s=(s+t)|0; } return s; } run();
