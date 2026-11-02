// Keep the property receiver/result above register255 inside a call window.
function wideKeepLast(){return arguments[301];}
var widePadding=[];
for(var wideIndex=0;wideIndex<301;wideIndex++)widePadding.push('0');
eval('function wideCachedRead(value){return wideKeepLast('+widePadding.join(',')+',value.slotValue);}');
var wideReceiver;
wideReceiver={slotValue:7};
for(var warm=0;warm<160;warm++){
    if(wideCachedRead(wideReceiver)!==7)throw 'wide cached warm';
}
wideReceiver='string';
if(wideCachedRead(wideReceiver)!==undefined)throw 'wide cached primitive retry';
wideReceiver={slotValue:9,extra:1};
if(wideCachedRead(wideReceiver)!==9)throw 'wide cached shape retry';
var wideGetterCalls=0;
wideReceiver={get slotValue(){wideGetterCalls++;return 11;}};
if(wideCachedRead(wideReceiver)!==11||wideGetterCalls!==1)throw 'wide cached getter retry';
console.log('WIDE cached retry: PASS');
