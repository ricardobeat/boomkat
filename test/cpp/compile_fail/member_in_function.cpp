// expect: bk::function binds free functions
#include "boomkat.hpp"
struct S { int get() const { return 1; } };
void bind(bk::Context cx) { (void)bk::function<&S::get>(cx, "get"); }
