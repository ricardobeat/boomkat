var a=[];for(var i=0;i<200000;i++)a.push({x:i,y:i});var sum=0;for(var j=0;j<a.length;j++)sum+=a[j].x;if(sum!==19999900000)throw new Error('checksum');print('allocation retained: passed');
