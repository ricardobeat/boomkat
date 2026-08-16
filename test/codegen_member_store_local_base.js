// A member assignment whose base is a live let/const home register and whose
// RHS is a runtime value. The store path freed the base register and
// immediately re-allocated it as the assignment-result temp, so the LDREG
// result copy overwrote the variable with the RHS. typescript 5.4.5's
// createBaseIdentifier hit this (`node.escapedText = text` turned `node`
// into the string) and died with "Cannot create property 'jsDoc' on string".

function storeParam(v) {
  const n = {};
  n.a = v;
  return typeof n;
}

function storeParamLet(v) {
  let n = {};
  n.a = v;
  return typeof n;
}

function storeFromOuter(o, v) {
  const n = o;
  n.a = v;
  return typeof n;
}

function storeComputed(v) {
  const n = {};
  n["a"] = v;
  return typeof n;
}

function storeTwoKeys(v) {
  const n = {};
  n.a = v;
  n.b = v;
  return typeof n;
}

function storeReadBack(v) {
  const n = { a: 0 };
  n.a = v;
  return n.a;
}

function factory(mk, s) {
  const node = mk();
  node.escapedText = s;
  node.jsDoc = void 0;
  return typeof node;
}

function storeThenAlloc(v) {
  const n = {};
  n.a = v;
  return [typeof n, n.a].join(":");
}

function check(name, got, want) {
  if (got !== want) throw new Error(name + ": got " + got + ", want " + want);
  print(name + " ok");
}

check("storeParam", storeParam("z"), "object");
check("storeParamLet", storeParamLet("z"), "object");
check("storeFromOuter", storeFromOuter({}, "z"), "object");
check("storeComputed", storeComputed("z"), "object");
check("storeTwoKeys", storeTwoKeys("z"), "object");
check("storeReadBack", storeReadBack("z"), "z");
check("factory", factory(function () { return {}; }, "x"), "object");
check("storeThenAlloc", storeThenAlloc("z"), "object:z");
