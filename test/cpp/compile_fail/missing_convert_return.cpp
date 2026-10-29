// expect: no bk::Convert<T> specialization
#include "boomkat.hpp"
struct Opaque { int x; };
static Opaque make() { return Opaque{1}; }
void bind(bk::Context cx) { (void)bk::function<&make>(cx, "make"); }
