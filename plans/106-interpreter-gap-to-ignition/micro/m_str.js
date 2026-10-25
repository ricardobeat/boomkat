bench("str_concat_charcode", 2000000, function(n){ var s=0; var t="abcdefghij"; for (var i=0;i<n;i++){ var u=t+i; s=(s+u.charCodeAt(3)+u.length)|0; } return s; });
