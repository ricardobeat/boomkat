// A pure cyclic callee must copy simultaneous phi inputs before replacing
// any destination, including swaps of the same static JOIN identities.
function SwapBox() {}
// Extra locals put the callee above the tiny-inline limits, selecting the
// frameless cyclic entry whose simultaneous JOIN copies caused the failure.
var pad='var q0=0,q1=0,q2=0,q3=0,q4=0,q5=0,q6=0,q7=0,q8=0,q9=0,q10=0,q11=0,q12=0,q13=0,q14=0,q15=0,q16=0,q17=0,q18=0,q19=0,q20=0,q21=0,q22=0,q23=0,q24=0;';
SwapBox.prototype.swap = new Function('n',pad+'var a=1,b=2,i=0;while(i<n){var t=a;a=b;b=t;i=i+1;}return a*17+b;');
var box=new SwapBox();
function callSwap(n){return box.swap(n);}
for(var round=0;round<4000;round++){
 var n=(round&7)+1, result=callSwap(n), expected=(n&1)?35:19;
 if(result!==expected)throw Error('pure cyclic swap '+round+' n='+n+' result='+result+' expected='+expected);
}
print('pure cyclic swap: PASS');

SwapBox.prototype.floatSwap = new Function('n',pad+'var a=1.5,b=2.25,i=0;while(i<n){var t=a;a=b;b=t;i=i+1;}return a*17+b;');
function callFloatSwap(n){return box.floatSwap(n);}
for(var round=0;round<4000;round++){
 var n=(round&7)+1, result=callFloatSwap(n), expected=(n&1)?39.75:27.75;
 if(result!==expected)throw Error('pure float swap '+round+' n='+n+' result='+result+' expected='+expected);
}
print('pure float cyclic swap: PASS');
