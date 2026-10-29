// expect: deleted
#include "boomkat.hpp"
void dup(bk::OwnedContext& a) { bk::OwnedContext b = a; (void)b; }
