// Repeated immutable records with nested data and a shared construction layout.
function point(i) { return {x:i,y:i+1,z:i+2,r:1,g:2,b:3}; }
function record(i) {
    return {id:i,name:'item',enabled:true,x:i,y:i+1,z:i+2,r:1,g:2,b:3,
            width:10,height:20,weight:1,visible:true,selected:false,opacity:1,version:0};
}
var total = 0;
var records = [];
for (var i = 0; i < 30000; i++) {
    var peer = point(i);
    var item = point(i);
    Object.freeze(item);
    peer.x = i + 10;
    if (peer.x !== i + 10 || Object.getOwnPropertyDescriptor(item,'x').writable)
        throw new Error('shared flags');
    var large = record(i);
    Object.seal(large);
    large.version = 2;
    Object.freeze(large);
    if (large.version !== 2 || !Object.isFrozen(item) || !Object.isFrozen(large))
        throw new Error('integrity');
    records.push(large);
    total += item.x + large.id;
}
if (total !== 899970000 || records[29999].id !== 29999) throw new Error('values');
print('PASS ' + total);
