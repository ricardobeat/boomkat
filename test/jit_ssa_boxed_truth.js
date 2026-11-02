// A decoded cyclic body whose condition keeps its boxed JavaScript value.
var truthSource = 'function nativeBoxedTruth(value,output){var n=0;for(var i=0;i<3;i++){if(value)n+=1;else n+=2;';
for (var pad=0;pad<70;pad++) truthSource += 'output[0]=n;';
truthSource += '}return n;}';
eval(truthSource);
var truthOutput=[0];
var truthObject={valueOf:function(){throw 'ToBoolean must not coerce';}};
var truthValues=[truthObject,null,undefined,true,false,0,1,-1];
var truthExpected=[3,6,6,3,6,6,3,3];
for(var warm=0;warm<128;warm++){
    for(var at=0;at<truthValues.length;at++){
        if(nativeBoxedTruth(truthValues[at],truthOutput)!==truthExpected[at]
            ||truthOutput[0]!==truthExpected[at])throw 'native boxed truth';
    }
}
// Unsupported representations recover before the condition, including NaN/-0.
var truthFallback=[NaN,-0,0.5,-0.5,'','yes',0n,1n,Symbol('')];
for(var at=0;at<truthFallback.length;at++){
    var expected=truthFallback[at]?3:6;
    if(nativeBoxedTruth(truthFallback[at],truthOutput)!==expected
        ||truthOutput[0]!==expected)throw 'boxed truth fallback';
}
console.log('SSA boxed truth: PASS');
