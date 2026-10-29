// expect: no bk::Convert<T> specialization
#include "boomkat.hpp"
struct Opaque { int x; };
static int take(Opaque o) { return o.x; }
void bind(bk::Context cx) { (void)bk::function<&take>(cx, "take"); }
