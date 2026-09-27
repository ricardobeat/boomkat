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

// The payload is the sole persistent owner of these dynamically built strings.
for (let round = 0; round < 20; round++) {
  let text = "retained-" + round + "-" + "x".repeat(4096);
  const retained = new Deflater(text);
  text = null;
  for (let i = 0; i < 1000; i++) ({ churn: i, value: "temporary-" + i });
  const returned = retained.tag;
  if (returned.length !== ("retained-" + round + "-").length + 4096 ||
      returned.slice(0, 9) !== "retained-") {
    throw new Error("retained string lost");
  }
}
console.log("payload string ownership OK");
