// expect: nodiscard
#include "boomkat.hpp"
void f(bk::Context cx) { cx.eval("1"); }
