// Two switches on the same let/const discriminant. The first switch freed
// the discriminant's home register at its end (a bare local read is not a
// temp), so the second switch's first case literal loaded into it and every
// comparison after that was a self-compare. typescript 5.4.5's
// checkSourceElementWorker hit this: a kind-260 node dispatched to the
// kind-243 handler.

function twoSwitches(k) {
  let kind = k;
  switch (kind) { case 1: break; }
  switch (kind) {
    case 2: return "two";
    case 3: return "three";
  }
  return "none";
}

function twoSwitchesConst(k) {
  const kind = k;
  switch (kind) { case 1: break; }
  switch (kind) {
    case 2: return "two";
    case 3: return "three";
  }
  return "none";
}

function threeSwitches(k) {
  const kind = k;
  switch (kind) { case 9: break; }
  switch (kind) { case 8: break; }
  switch (kind) {
    case 2: return "two";
    case 3: return "three";
    case 4: return "four";
  }
  return "none";
}

// Small switch nested in an if before the real dispatch, the shape the
// typescript checker uses for its cancellation check.
function guarded(k, cancel) {
  const kind = k;
  if (cancel) {
    switch (kind) {
      case 267:
      case 263:
        throw new Error("cancelled");
    }
  }
  switch (kind) {
    case 267: return "a";
    case 243: return "VS";
    case 260: return "VD";
  }
  return "none";
}

// String discriminants, the non-fastint path.
function stringDisc(k) {
  const kind = k;
  switch (kind) { case "x": break; }
  switch (kind) {
    case "a": return 1;
    case "b": return 2;
  }
  return 0;
}

// The for-increment of the same shape: `++i` returns i's home register.
function forIncr() {
  let i = 0;
  let out = 0;
  for (; i < 3; ++i) { out = i; }
  const j = i;
  switch (j) {
    case 3: return "three:" + out;
    case 4: return "four";
  }
  return "none";
}

function check(name, got, want) {
  if (got !== want) throw new Error(name + ": got " + got + ", want " + want);
  print(name + " ok");
}

check("twoSwitches(2)", twoSwitches(2), "two");
check("twoSwitches(3)", twoSwitches(3), "three");
check("twoSwitchesConst(2)", twoSwitchesConst(2), "two");
check("twoSwitchesConst(3)", twoSwitchesConst(3), "three");
check("threeSwitches(3)", threeSwitches(3), "three");
check("threeSwitches(4)", threeSwitches(4), "four");
check("guarded(243)", guarded(243, false), "VS");
check("guarded(260)", guarded(260, false), "VD");
check("guarded(267)", guarded(267, false), "a");
check("guarded(267, true) throws", (function () {
  try { guarded(267, true); return "no"; } catch (e) { return "yes"; }
})(), "yes");
check("stringDisc(a)", stringDisc("a"), 1);
check("stringDisc(b)", stringDisc("b"), 2);
check("stringDisc(c)", stringDisc("c"), 0);
check("forIncr", forIncr(), "three:2");
