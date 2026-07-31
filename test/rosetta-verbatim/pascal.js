// Verbatim from https://rosettacode.org/wiki/Pascal%27s_triangle (JavaScript block 3)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
const aux = n => {
  if(n <= 1) return [1]
  const prevLayer = aux(n - 1)
  const shifted = [0, ...prevLayer]
  return shifted.map((x, i) => (prevLayer[i] || 0) + x)
}
const pascal = n => {
  for(let i = 1; i <= n; i++) {
    console.log(aux(i).join(' '))
  }
}
pascal(8)
