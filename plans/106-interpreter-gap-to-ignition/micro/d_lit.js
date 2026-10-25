var N=20000000;
function run(){ var s=0; for (var i=0;i<N;i++) { var o={x:i}; s=(s+o.x)|0; } return s; } run();
