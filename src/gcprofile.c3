// Collection-pressure profiling counters (feature GC_PROFILE).
//
// Time spent in mark_tval can come from a large live heap or from collecting
// too frequently. A high marked_per_alloc ratio distinguishes the two: it
// signals that the collector repeatedly rescans an unchanging live set
// between small batches of allocations.
//
// Gated on GC_PROFILE. Default builds omit the counters and increments.
module boomkat::gcprofile;

import std::io;

ulong gcprof_allocations;
ulong gcprof_reallocs;
ulong gcprof_last_live;
ulong gcprof_cycles;
ulong gcprof_marked;
ulong gcprof_swept;

macro void gcprof_alloc() @builtin {
    $if $feature(GC_PROFILE):
    gcprof_allocations++;
    $endif
}

// Reallocations decrement the heap GC trigger like allocations do,
// contributing to collection pressure.
macro void gcprof_realloc() @builtin {
    $if $feature(GC_PROFILE):
    gcprof_reallocs++;
    $endif
}

macro void gcprof_mark() @builtin {
    $if $feature(GC_PROFILE):
    gcprof_marked++;
    $endif
}

macro void gcprof_cycle(ulong swept) @builtin {
    $if $feature(GC_PROFILE):
    gcprof_cycles++;
    gcprof_swept += swept;
    gcprof_last_live = swept;
    $endif
}

// Dump collection pressure to stderr. Call once at interpreter shutdown.
fn void gcprof_dump() {
$if $feature(GC_PROFILE):
    io::eprintfn("# GC_PROFILE allocations=%d reallocs=%d cycles=%d marked=%d swept=%d",
                 gcprof_allocations, gcprof_reallocs, gcprof_cycles, gcprof_marked, gcprof_swept);
    io::eprintfn("#   live_obj_count_at_last_cycle=%d", gcprof_last_live);
    if (gcprof_cycles > 0) {
        io::eprintfn("#   allocs_per_cycle=%d marked_per_cycle=%d",
                     gcprof_allocations / gcprof_cycles,
                     gcprof_marked / gcprof_cycles);
    }
    if (gcprof_allocations > 0) {
        // Marking work done per allocation. Compare across runs rather than
        // against an absolute threshold, since the baseline depends on the
        // live heap size. A ratio that grows while allocation rate stays flat
        // indicates the collection budget is scaled too tightly to the live
        // object count. See GC_TRIGGER_GROW_FACTOR in heap.c3.
        io::eprintfn("#   marked_per_alloc=%.2f  (compare across runs; a rise means more collections over the same live set)",
                     (double)gcprof_marked / (double)gcprof_allocations);
    }
$endif
}
