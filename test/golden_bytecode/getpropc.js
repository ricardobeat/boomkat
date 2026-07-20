// GETPROPC fusion: LDCONST rK, idx + GETPROP ra = rb, rK -> GETPROPC ra = rb, idx.
function getX(obj) {
  return obj.x;
}
getX({ x: 42 });
