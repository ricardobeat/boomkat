// The branch reads the old counter; phi copies must not replace it first.
function ssaPostfix(buffer, pos, count, value) {
    while (count-- > 0) buffer[pos++] = value;
    return pos * 1000 + count;
}
for (var trial = 0; trial < 200; trial++) {
    var count = trial % 47 + 1, buffer = new Uint8Array(80);
    if (ssaPostfix(buffer, 3, count, 17) !== (count + 3) * 1000 - 1)
        throw Error('postfix frame ' + trial);
    for (var i = 0; i < buffer.length; i++) {
        if (buffer[i] !== (i >= 3 && i < count + 3 ? 17 : 0))
            throw Error('postfix store ' + trial + ':' + i);
    }
}
print('SSA postfix branch: PASS');
