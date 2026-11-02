// A property read at a register above 255 encodes its GETPROPC with a WIDE
// prefix. When the inline cache at that site goes cold, the engine
// downgrades the site to the plain read and runs it again; the downgrade has
// to keep the WIDE prefix, or the re-run decodes truncated register indices
// and reads the wrong object.
//
// The nested calls push the read's destination register above 255 while
// keeping the constant pool small enough for the read to stay a GETPROPC.
var depth = 130;
var expr = 'o.k';
for (var i = 0; i < depth; i++) expr = 'step(' + expr + ')';
var read = new Function('o', 'return ' + expr + ';');

function step(x) { return x + 1; }

// The first call warms the site's inline cache; the second brings a
// different shape, so the site is downgraded and re-read.
if (read({ k: 1 }) !== 131) throw new Error('warm read');
if (read({ k: 1, other: 2 }) !== 131) throw new Error('downgraded read');
print('ok');
