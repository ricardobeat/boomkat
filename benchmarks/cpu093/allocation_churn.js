var sum=0;function make(i){return {x:i,y:i};}for(var i=0;i<1500000;i++){var o=make(i);sum+=o.x;}if(sum!==1124999250000)throw new Error('checksum');print('allocation churn: passed');
