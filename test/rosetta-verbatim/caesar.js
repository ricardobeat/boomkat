// Verbatim from https://rosettacode.org/wiki/Caesar_cipher (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function caesar (text, shift) {
  return text.toUpperCase().replace(/[^A-Z]/g,'').replace(/./g, function(a) {
    return String.fromCharCode(((a.charCodeAt(0) - 65 + shift) % 26 + 26) % 26 + 65);
  });
}

// Tests
var text = 'veni, vidi, vici';
for (var i = 0; i<26; i++) {
  console.log(i+': '+caesar(text,i));
}
