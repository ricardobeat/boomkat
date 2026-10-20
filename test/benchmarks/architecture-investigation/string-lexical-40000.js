var start=Date.now();
let s="";
for(var i=0;i<40000;i++)s+="abcde";
var elapsed=Date.now()-start;
var consumed=s.charCodeAt(s.length-1)+s.length;
print(elapsed+":"+consumed);