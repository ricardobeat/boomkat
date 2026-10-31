var atoms = ['(a|b)', '(?:ab|c)', '(?=x)', '(?!z)', '[ab]', '[^x]', '\\b', '^', '(?<=a)', '(?:a)?'];
var middle = ['longword', 'alpha\\.beta', 'alpha\\/beta', 'abcd?', 'abcdef*', 'abcdef+', 'abc{0,2}def', 'abc\\wdef', 'abc\\x64ef', 'abcdefghijklmnopq?'];
var tails = ['', '$', '(x|y)', '.*z', '|escape', '(?:x)?'];
var flags = ['', 'g', 'y', 'i', 'u'];
var inputs = ['', 'alongword', 'blongword', 'ablongwordx', 'xlongword', ' escape', 'fallback', 'aalpha.beta', 'balpha/beta', 'aabc', 'aabcdef', 'aabcdddef', 'aabcXdef', 'aabcdefghijklmnop', '\ud83d\ude00blongword', 'caféblongword', 'longword'];
for (var a=0;a<atoms.length;a++) for(var b=0;b<middle.length;b++) for(var c=0;c<tails.length;c++) for(var f=0;f<flags.length;f++) {
  var p=atoms[a]+middle[b]+tails[c], re;
  try { re=new RegExp(p,flags[f]); } catch(e) { print('error '+a+','+b+','+c+','+f); continue; }
  for(var j=0;j<inputs.length;j++) {
    re.lastIndex = j%3;
    var m=re.exec(inputs[j]);
    print(a+','+b+','+c+','+f+','+j+':'+JSON.stringify(m ? [m.index,Array.from(m),re.lastIndex] : [null,re.lastIndex]));
  }
}
