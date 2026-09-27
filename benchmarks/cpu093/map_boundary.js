var c=new Map();for(var i=0;i<256;i++)c.set(i,i);var sum=0;for(var j=0;j<200000;j++)if(c.has(j%256))sum++;if(sum!==200000)throw new Error("checksum");print("index hits: passed");
