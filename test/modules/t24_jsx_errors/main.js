// Malformed JSX is a SyntaxError, and `.js` files do not parse JSX.
for (const spec of ['./mismatch.jsx', './unterminated.jsx', './badattr.jsx', './plain.js']) {
  let err;
  try { await import(spec); } catch (e) { err = e; }
  if (!(err instanceof SyntaxError)) throw new Error(spec + ': ' + err);
}
