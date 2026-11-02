function nativeBindingCheck(ok,name){if(!ok)throw new Error(name);}
function nativeBindingFactory(){
    let width=8,rowSize=10;
    function nativeScalarRead(output,count){
        var sum=0;
        for(var i=0;i<count;i++){sum=sum+width+rowSize;output[i]=sum;}
        return sum;
    }
    function nativeScalarMutate(value){width=value;rowSize=value+2;}
    function nativeScalarCallback(output,count,callback){
        var sum=0;
        for(var i=0;i<count;i++){
            sum=sum+width;output[i]=sum;callback();sum=sum+rowSize;
        }
        return sum;
    }
    return [nativeScalarRead,nativeScalarMutate,nativeScalarCallback];
}
var nativeBindingPair=nativeBindingFactory();
var nativeScalarRead=nativeBindingPair[0];
var nativeScalarMutate=nativeBindingPair[1];
var nativeScalarCallback=nativeBindingPair[2];
var nativeBindingOutput=[0,0,0,0,0,0,0,0];
for(var warm=0;warm<160;warm++)nativeBindingCheck(nativeScalarRead(nativeBindingOutput,8)===144,'scalar captures');
nativeScalarMutate(11);
nativeBindingCheck(nativeScalarRead(nativeBindingOutput,8)===192,'fresh mutable cells');
var nativeBindingCalls=0;
function nativeBindingChange(){nativeBindingCalls++;nativeScalarMutate(20);}
for(var warm=0;warm<96;warm++){
    nativeScalarMutate(11);
    nativeBindingCheck(nativeScalarCallback(nativeBindingOutput,2,nativeBindingChange)===75,'callback refresh');
}
// A string binding takes the owning VM read path rather than borrowing a
// refcounted value through an aliased native write.
nativeScalarMutate('x');
nativeBindingCheck(nativeScalarRead(nativeBindingOutput,1)==='0xx2','string read');
nativeScalarMutate(8);
nativeBindingCheck(nativeScalarRead(nativeBindingOutput,8)===144,'numeric reentry');

function nativeBindingTdzFactory(early,output){
    function nativeTdzRead(output,count){
        var sum=0;
        for(var i=0;i<count;i++){output[i]=i+1;sum=sum+hidden;}
        return sum;
    }
    if(early)nativeTdzRead(output,1);
    let hidden=3;
    return nativeTdzRead;
}
var nativeTdzRead=nativeBindingTdzFactory(false,nativeBindingOutput);
for(var warm=0;warm<128;warm++)nativeBindingCheck(nativeTdzRead(nativeBindingOutput,4)===12,'tdz warm');
var nativeTdzCaught=false;
try{nativeBindingTdzFactory(true,nativeBindingOutput);}catch(error){nativeTdzCaught=error instanceof ReferenceError;}
nativeBindingCheck(nativeTdzCaught&&nativeBindingOutput[0]===1,'new closure tdz after effect');

// Guarded shadow lookup must retain with-object behavior.
var nativeWithObject={width:5};
var nativeWithRead;
with(nativeWithObject){nativeWithRead=function(output,count){var sum=0;for(var i=0;i<count;i++){output[i]=i+1;sum=sum+width;}return sum;};}
for(var warm=0;warm<96;warm++)nativeBindingCheck(nativeWithRead(nativeBindingOutput,4)===20,'with read');
nativeWithObject.width=9;
nativeBindingCheck(nativeWithRead(nativeBindingOutput,4)===36,'with mutation');
console.log('native SSA binding reads: PASS');
