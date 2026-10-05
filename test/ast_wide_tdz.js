var b69 = 99;
function wideTDZ(read) {
    if (read) return b69;
    let b0 = 0, b1 = 1, b2 = 2, b3 = 3, b4 = 4, b5 = 5, b6 = 6, b7 = 7, b8 = 8, b9 = 9,
        b10 = 10, b11 = 11, b12 = 12, b13 = 13, b14 = 14, b15 = 15, b16 = 16, b17 = 17, b18 = 18, b19 = 19,
        b20 = 20, b21 = 21, b22 = 22, b23 = 23, b24 = 24, b25 = 25, b26 = 26, b27 = 27, b28 = 28, b29 = 29,
        b30 = 30, b31 = 31, b32 = 32, b33 = 33, b34 = 34, b35 = 35, b36 = 36, b37 = 37, b38 = 38, b39 = 39,
        b40 = 40, b41 = 41, b42 = 42, b43 = 43, b44 = 44, b45 = 45, b46 = 46, b47 = 47, b48 = 48, b49 = 49,
        b50 = 50, b51 = 51, b52 = 52, b53 = 53, b54 = 54, b55 = 55, b56 = 56, b57 = 57, b58 = 58, b59 = 59,
        b60 = 60, b61 = 61, b62 = 62, b63 = 63, b64 = 64, b65 = 65, b66 = 66, b67 = 67, b68 = 68, b69 = 69;
    return b69;
}
var threw = false;
try { wideTDZ(true); } catch (error) { threw = error instanceof ReferenceError; }
if (!threw) throw new Error('the final binding bypassed its TDZ');
if (wideTDZ(false) !== 69 || b69 !== 99) throw new Error('wrong lexical binding');
print('ast_wide_tdz: ok');
