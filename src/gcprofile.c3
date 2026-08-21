// Collection-pressure counters (feature GC_PROFILE).
//
// `sample` tells you time is going into mark_tval; it cannot tell you whether
// that is the cost of a large live heap or of collecting far too often. Those
// need opposite fixes, and the ratio that separates them is not visible in a
// profile.
//
// A `for (const x of arr)` over a 200k array ran 629x slower than QuickJS with
// over 90% of samples in mark_tval. The array was not the problem and neither
// was the iterator: the collection budget between cycles was scaled at 1x the
// live object count, so a program holding N live objects collected every N
// allocations and re-marked all N each time. Quadratic in the live set. An
// index loop over the same array was fine, because it allocates nothing per
// step while the iterator protocol allocates a result object per step.
//
// marked_per_alloc is the number that makes that visible. Marking many objects
// per allocation means the collector is re-scanning a live heap that is not
// changing, and the budget wants raising -- no amount of staring at a sampled
// profile says so directly.
//
// Gated on GC_PROFILE, which no shipping target enables, so the default build
// carries neither the counters nor their increments.
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

// Count a realloc. It decrements the same GC trigger an allocation does, so
// leaving it out understates what is actually driving collections.
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
        // The diagnostic ratio: marking work done per unit of allocation.
        //
        // Read it by COMPARING two runs, not against an absolute threshold --
        // its floor is set by how large a live heap the workload legitimately
        // holds. Over a 100k array, an index loop sits around 140 while the
        // same loop written as for-of sits around 227, and that gap is the
        // signal: the iterator allocates a result object per step, so it pays
        // for far more collections over the same unchanging live set.
        //
        // A ratio that rises when the live heap grows but the program's real
        // work does not is the signature of a collection budget scaled too
        // tightly to the live count. See GC_TRIGGER_GROW_FACTOR in heap.c3.
        io::eprintfn("#   marked_per_alloc=%.2f  (compare across runs; a rise means more collections over the same live set)",
                     (double)gcprof_marked / (double)gcprof_allocations);
    }
$endif
}
