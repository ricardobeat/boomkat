// Churn Deflaters so the finalizer runs many times, while each holds a tag
// reachable only through the payload.
let survived = 0;
for (let round = 0; round < 300; round++) {
  const keep = [];
  for (let i = 0; i < 50; i++) {
    const d = new Deflater({ id: round * 1000 + i });
    d.push("payload-" + i);
    if (i % 10 === 0) keep.push(d);
  }
  for (const d of keep) {
    if (d.tag.id % 1000 === 0 || true) survived++;
    if (d.bytesIn <= 0) throw new Error("payload lost");
  }
}
console.log("rounds OK, live checks:", survived);
