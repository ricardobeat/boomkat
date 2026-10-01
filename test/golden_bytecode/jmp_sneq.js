// Strict-inequality branch fusion: !== in a while condition → JMP_SEQ
function count(n, limit) { var i = 0; while (i !== limit) { i = i + 1; } return i; }
print(count(5, 5));
