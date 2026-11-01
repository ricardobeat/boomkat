// expect: deleted
#include "boomkat.hpp"
bk::Value* leak(bk::Value v) { return new bk::Value(v); }
