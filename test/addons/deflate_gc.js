loadAddon("addons/deflate/deflate.dylib");
let checks = 0;
for (let round = 0; round < 200; round++) {
  const keep = [];
  for (let i = 0; i < 50; i++) {
    const d = new Deflater({ id: round * 1000 + i });
    d.push("payload-" + i);
    if (i % 10 === 0) keep.push(d);
  }
  for (const d of keep) {
    if (d.tag.id !== undefined && d.bytesIn > 0) checks++;
    else throw new Error("payload or tag lost");
  }
}
console.log("gc stress OK, checks:", checks);
