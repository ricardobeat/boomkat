// Strict-inequality branch fusion: !== in a while condition → JMP_SEQ
function count(n) { var i = 0; while (i !== n) { i = i + 1; } return i; }
print(count(5));
