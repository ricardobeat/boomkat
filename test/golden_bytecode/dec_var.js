// DEC_VAR fusion: GETVAR r,name + DEC r + PUTVAR r,name -> DEC_VAR name.
// `i` must be forced env-resident (captured by the inner closure) or the
// register-resident-locals pass would elide GETVAR/PUTVAR entirely and this
// fusion would never get a chance to fire.
function counter() {
  var i = 5;
  function capture() { return i; }
  while (i > 0) {
    i--;
  }
  return capture();
}
counter();
