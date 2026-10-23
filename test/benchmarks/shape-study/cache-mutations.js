function read(o) { return o.value; }
function check(a, b, expectedA, expectedB) {
    for (var i = 0; i < 1000; i++) {
        if (read(a) !== expectedA || read(b) !== expectedB) throw new Error('stale read');
    }
}
var a = {value:1};
var b = {padding:0,value:2};
check(a,b,1,2);
a.value = 3;
check(a,b,3,2);
Object.defineProperty(a,'value',{get:function(){return 4;},configurable:true});
check(a,b,4,2);
delete a.value;
Object.setPrototypeOf(a,{value:5});
check(a,b,5,2);
Object.defineProperty(a,'value',{value:6,writable:true,configurable:true});
check(a,b,6,2);
for (var i = 0; i < 100; i++) b['field'+i] = i;
check(a,b,6,2);
var proxy = new Proxy({value:7},{get:function(target,key){return key === 'value' ? 8 : target[key];}});
check(a,proxy,6,8);
var retained = [];
for (var i = 0; i < 20000; i++) retained.push({a:i,b:'x'+i,c:i,d:i,e:i,f:i});
check(a,b,6,2);
print('PASS');
