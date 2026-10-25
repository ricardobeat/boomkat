var N=20000000;
function e(a){ return a; } function run(){ var s=0; for (var i=0;i<N;i++) { s=(s+e(i))|0; } return s; } run();
