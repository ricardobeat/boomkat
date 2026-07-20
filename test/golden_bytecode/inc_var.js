// INC_VAR fusion: GETVAR r,name + INC r + PUTVAR r,name -> INC_VAR name.
// `i` must be forced env-resident (captured by the inner closure) or the
// register-resident-locals pass would elide GETVAR/PUTVAR entirely and this
// fusion would never get a chance to fire.
function counter() {
  var i = 0;
  function capture() { return i; }
  while (i < 5) {
    i++;
  }
  return capture();
}
counter();
