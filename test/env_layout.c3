// Layout probe for plans/085; compare proposed metadata with runtime types.
module env_layout;

import std::io;
import boomkat::env;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;

bitstruct PlannedEnvFlags : char {
    bool is_declarative : 0;
    bool is_function_scope : 1;
    bool is_with : 2;
    bool is_catch : 3;
    bool allocated : 4;
    bool mark_epoch : 5;
    bool temproot : 6;
}

struct PlannedEnv {
    PlannedEnv* parent;
    HObject* bindings;
    PlannedEnvFlags flags;
    Heap* heap;
}

struct PlannedBlock {
    PlannedBlock* next;
    PlannedEnv[env::ENV_POOL_BLOCK_SIZE] cells;
}

// Appending ENVREF preserves existing discriminator ordinals and backing size.
enum PlannedTag : char {
    UNDEFINED, NULL_VAL, BOOLEAN, NUMBER, FASTINT, STRING, OBJECT, BUFFER,
    POINTER, LIGHTFUNC, BIGINT, DELETED, ENVREF,
}
struct PlannedUnionTVal {
    PlannedTag tag;
    union {
        bool boolean;
        double number;
        long fastint;
        void* pointer;
    }
}

fn void main() {
    EnvRecord current;
    PlannedEnv planned;
    io::printfn("env current=%d proposed=%d alignment=%d flags=%d heap_offset=%d/%d block=%d",
        EnvRecord::size, PlannedEnv::size, PlannedEnv::alignment,
        PlannedEnvFlags::size,
        (usz)&current.heap - (usz)&current,
        (usz)&planned.heap - (usz)&planned, PlannedBlock::size);
    assert(EnvRecord::size == PlannedEnv::size);
    assert(EnvRecord::alignment == PlannedEnv::alignment);
    assert((usz)&current.heap - (usz)&current == (usz)&planned.heap - (usz)&planned);
    assert(PlannedEnvFlags::size == 1);
    io::printfn("nanbox=%s runtime_tval=%d proposed_union=%d union_alignment=%d",
        types::USE_NANBOX ? "true" : "false", TVal::size,
        PlannedUnionTVal::size, PlannedUnionTVal::alignment);
$if !types::USE_NANBOX:
    TVal actual;
    PlannedUnionTVal proposed;
    assert(TVal::size == PlannedUnionTVal::size);
    assert(TVal::alignment == PlannedUnionTVal::alignment);
    assert((usz)&actual.pointer - (usz)&actual == (usz)&proposed.pointer - (usz)&proposed);
$endif
}
