var work = (n) => { var s=0; var peek=()=>s; for(var i=0;i<n;i++)s=peek()+1; return s; };
var sum=work(3000000); if(sum!==3000000)throw new Error('checksum'); print('arrow capture: passed');
