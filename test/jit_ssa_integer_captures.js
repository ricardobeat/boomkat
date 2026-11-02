// Shared closure code must recheck the current captured value on every read.
var captureIntegerSource = 'function captureIntegerFactory(initial){var stride=initial;function changeCaptureInteger(value){stride=value;}function nativeCaptureInteger(a,out,n,callback){var sum=0;for(var row=1;row<=2;row++){var pos=row*stride;out[3]=pos;for(var col=0;col<n;col++){sum+=a[pos];pos++;out[1]++;';
for(var pad=0;pad<85;pad++)captureIntegerSource+='out[0]=sum;';
captureIntegerSource+='}out[4]++;if(row===1&&callback)callback();}return sum;}return{run:nativeCaptureInteger,set:changeCaptureInteger};}';
eval(captureIntegerSource);
var captureInteger = captureIntegerFactory(4);
var captureIntegerArray=[];
for(var at=0;at<64;at++)captureIntegerArray[at]=at+0.25;
var captureIntegerOutput=[0,0,0,0,0];
function resetCaptureIntegerOutput(){for(var at=0;at<5;at++)captureIntegerOutput[at]=0;}
for(var warm=0;warm<128;warm++){
    resetCaptureIntegerOutput();
    if(captureInteger.run(captureIntegerArray,captureIntegerOutput,2,null)!==27||captureIntegerOutput[1]!==4||captureIntegerOutput[4]!==2)throw 'integer capture warm';
}
function checkCaptureIntegerRecovery(){
    var out=captureIntegerOutput;
    captureIntegerArray['1.5']=100;captureIntegerArray['2.5']=200;
    captureInteger.set(1.5);resetCaptureIntegerOutput();
    if(captureInteger.run(captureIntegerArray,out,2,null)!==307.5||out[1]!==4||out[4]!==2)throw 'fractional capture';
    captureInteger.set(-0);resetCaptureIntegerOutput();
    if(captureInteger.run(captureIntegerArray,out,1,null)!==0.5||1/out[3]!==-Infinity||out[1]!==2||out[4]!==2)throw 'negative zero capture';
    captureInteger.set(2147483647);resetCaptureIntegerOutput();
    if(captureInteger.run(captureIntegerArray,out,0,null)!==0||out[3]!==4294967294||out[4]!==2)throw 'checked capture multiply overflow';
    captureInteger.set(2147483648);resetCaptureIntegerOutput();
    if(captureInteger.run(captureIntegerArray,out,0,null)!==0||out[3]!==4294967296||out[4]!==2)throw 'out of range capture';
    var coercions=0;
    captureInteger.set({valueOf:function(){coercions++;return 4;}});resetCaptureIntegerOutput();
    if(captureInteger.run(captureIntegerArray,out,0,null)!==0||out[3]!==8||coercions!==2||out[4]!==2)throw 'capture coercion exactly once';
    var callbacks=0;
    captureInteger.set(4);resetCaptureIntegerOutput();
    if(captureInteger.run(captureIntegerArray,out,2,function(){callbacks++;captureInteger.set(1.5);})!==17||callbacks!==1||out[1]!==4||out[4]!==2)throw 'capture callback late recovery';
    captureInteger.set(4);resetCaptureIntegerOutput();callbacks=0;
    if(captureInteger.run(captureIntegerArray,out,2,function(){callbacks++;captureInteger.set(7);})!==39||callbacks!==1||out[1]!==4||out[3]!==14||out[4]!==2)throw 'capture integer alias refresh';
    var other=captureIntegerFactory(1.5);resetCaptureIntegerOutput();
    if(other.run(captureIntegerArray,out,2,null)!==307.5||out[1]!==4||out[4]!==2)throw 'different closure same code';
    captureInteger.set(4);
}
checkCaptureIntegerRecovery();
console.log('SSA integer captures: PASS');
