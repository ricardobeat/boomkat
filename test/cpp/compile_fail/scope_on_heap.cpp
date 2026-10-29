// expect: deleted
#include "boomkat.hpp"
bk::Scope* leak(bk::Context cx) { return new bk::Scope(cx); }
