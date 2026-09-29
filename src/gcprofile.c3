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
import std::time;

ulong gcprof_string_allocations;
ulong gcprof_string_frees;
ulong gcprof_ascii_char_allocations;
ulong gcprof_ascii_char_frees;
ulong gcprof_string_bytes;
ulong gcprof_string_peak_bytes;
ulong gcprof_allocations;
ulong gcprof_pool_allocations;
ulong gcprof_pool_bytes;
ulong gcprof_regexp_lastindex_fast_reads;
ulong gcprof_regexp_lastindex_fast_writes;
ulong gcprof_reallocs;
ulong gcprof_last_live;
ulong gcprof_cycles;
ulong gcprof_marked;
ulong gcprof_swept;
ulong gcprof_function_envs;
ulong gcprof_declarative_envs;
ulong gcprof_object_envs;
ulong gcprof_await_suspensions;
ulong gcprof_await_fullregs;
ulong gcprof_await_savedspan;
ulong gcprof_await_copiedlive;
ulong gcprof_minor_cycles;
ulong gcprof_major_cycles;
ulong gcprof_young_swept;
ulong gcprof_old_swept;
ulong gcprof_remembered_owners;

macro void gcprof_generation(bool minor) @builtin {
    $if $feat(GC_PROFILE):
        if (minor) { gcprof_minor_cycles++; }
        else { gcprof_major_cycles++; }
    $endif
}

macro void gcprof_sweep_node(bool old) @builtin {
    $if $feat(GC_PROFILE):
        if (old) { gcprof_old_swept++; }
        else { gcprof_young_swept++; }
    $endif
}

macro void gcprof_remembered_owner() @builtin {
    $if $feat(GC_PROFILE):
        gcprof_remembered_owners++;
    $endif
}

macro void gcprof_string_alloc(usz bytes) @builtin {
    $if $feat(GC_PROFILE):
        gcprof_string_allocations++;
        gcprof_string_bytes += bytes;
        if (gcprof_string_bytes > gcprof_string_peak_bytes) {
            gcprof_string_peak_bytes = gcprof_string_bytes;
        }
    $endif
}

macro void gcprof_string_free(usz bytes) @builtin {
    $if $feat(GC_PROFILE):
        gcprof_string_frees++;
        gcprof_string_bytes -= bytes;
    $endif
}

macro void gcprof_ascii_char_alloc() @builtin {
    $if $feat(GC_PROFILE):
        gcprof_ascii_char_allocations++;
    $endif
}

macro void gcprof_ascii_char_free() @builtin {
    $if $feat(GC_PROFILE):
        gcprof_ascii_char_frees++;
    $endif
}

macro void gcprof_await_save(uint fullregs, uint savedspan, uint copiedlive) @builtin {
    $if $feat(GC_PROFILE):
    gcprof_await_suspensions++;
    gcprof_await_fullregs += fullregs;
    gcprof_await_savedspan += savedspan;
    gcprof_await_copiedlive += copiedlive;
    $endif
}

macro void gcprof_env(bool function_scope, bool declarative) @builtin {
    $if $feat(GC_PROFILE):
    if (function_scope) {
        gcprof_function_envs++;
    } else if (declarative) {
        gcprof_declarative_envs++;
    } else {
        gcprof_object_envs++;
    }
    $endif
}

macro void gcprof_alloc() @builtin {
    $if $feat(GC_PROFILE):
    gcprof_allocations++;
    $endif
}

// Successful Heap.pool_alloc requests and their requested sizes. This tracks
// object backing blocks as well as other pooled storage, which lets focused
// allocation probes see copying/growth hidden from the object count.
macro void gcprof_pool_alloc(usz bytes) @builtin {
    $if $feat(GC_PROFILE):
    gcprof_pool_allocations++;
    gcprof_pool_bytes += bytes;
    $endif
}

macro void gcprof_regexp_lastindex_fast_read() @builtin {
    $if $feat(GC_PROFILE):
    gcprof_regexp_lastindex_fast_reads++;
    $endif
}

macro void gcprof_regexp_lastindex_fast_write() @builtin {
    $if $feat(GC_PROFILE):
    gcprof_regexp_lastindex_fast_writes++;
    $endif
}

// Reallocations decrement the heap GC trigger like allocations do,
// contributing to collection pressure.
macro void gcprof_realloc() @builtin {
    $if $feat(GC_PROFILE):
    gcprof_reallocs++;
    $endif
}

macro void gcprof_mark() @builtin {
    $if $feat(GC_PROFILE):
    gcprof_marked++;
    $endif
}

macro void gcprof_cycle(ulong swept) @builtin {
    $if $feat(GC_PROFILE):
    gcprof_cycles++;
    gcprof_swept += swept;
    gcprof_last_live = swept;
    $endif
}

// Dump collection pressure to stderr. Call once at interpreter shutdown.
fn void gcprof_dump() {
$if $feat(GC_PROFILE):
    io::eprintfn("# GC_STRINGS allocations=%d frees=%d live_bytes=%d peak_bytes=%d",
        gcprof_string_allocations, gcprof_string_frees,
        gcprof_string_bytes, gcprof_string_peak_bytes);
    io::eprintfn("# GC_ASCII_CHARS allocations=%d frees=%d",
        gcprof_ascii_char_allocations, gcprof_ascii_char_frees);
    String[12] names = {"finish_previous_sweep", "seed_pins", "roots_and_graph",
        "remembered_graph", "weak_caches", "young_sweep", "env_sweep",
        "strings", "collection_pause", "lazy_sweep_pause", "reserved", "reserved"};
    String[12] incremental_names = {"roots", "mark", "weak", "sweep", "env",
        "strings", "finalize", "slice", "blocking_collection", "root_publication", "string_table_maintenance", "string_table_lookup"};
    for (uint i = 0; i < 36; i++) {
        if (phase_count[i] == 0) continue;
        io::eprintfn("# GC_PHASE kind=%s phase=%s count=%d total_ms=%.3f max_ms=%.3f over_4ms=%d",
            i < 12 ? "minor" : (i < 24 ? "major" : "cooperative"),
            i < 24 ? names[i % 12] : incremental_names[i - 24], phase_count[i],
            (double)phase_total[i] / 1e6, (double)phase_max[i] / 1e6, phase_over_budget[i]);
    }
    if (phase_count[31] > 0) {
        io::eprintfn("# GC_PAUSES count=%d p50_us=%d p95_us=%d p99_us=%d p999_us=%d max_us=%.3f",
            phase_count[31], pause_percentile(500), pause_percentile(950),
            pause_percentile(990), pause_percentile(999), (double)phase_max[31] / 1000.0);
    }
    io::eprintfn("# GC_PROFILE allocations=%d reallocs=%d cycles=%d marked=%d swept=%d",
                 gcprof_allocations, gcprof_reallocs, gcprof_cycles, gcprof_marked, gcprof_swept);
    io::eprintfn("# GC_POOL allocations=%d requested_bytes=%d",
                 gcprof_pool_allocations, gcprof_pool_bytes);
    io::eprintfn("# GC_REGEXP_LASTINDEX fast_reads=%d fast_writes=%d",
                 gcprof_regexp_lastindex_fast_reads,
                 gcprof_regexp_lastindex_fast_writes);
    io::eprintfn("# GC_GENERATIONS minors=%d majors=%d young_swept=%d old_swept=%d remembered_owners=%d",
        gcprof_minor_cycles, gcprof_major_cycles, gcprof_young_swept,
        gcprof_old_swept, gcprof_remembered_owners);
    io::eprintfn("#   live_obj_count_at_last_cycle=%d", gcprof_last_live);
    io::eprintfn("#   environments function=%d declarative=%d object=%d",
                 gcprof_function_envs, gcprof_declarative_envs, gcprof_object_envs);
    io::eprintfn("#   await suspensions=%d fullregs=%d savedspan=%d copiedlive=%d",
                 gcprof_await_suspensions, gcprof_await_fullregs,
                 gcprof_await_savedspan, gcprof_await_copiedlive);
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

// Phase clocks run only at collection boundaries; no per-edge timer calls.
ulong[36] phase_total;
ulong[36] phase_max;
ulong[36] phase_count;
ulong[36] phase_over_budget;

// Ten-microsecond buckets report percentile upper bounds. The last bucket
// contains overflow; phase_max preserves the exact maximum independently.
ulong[4097] pause_histogram;

fn ulong pause_percentile(ulong permille) {
    ulong target = (phase_count[31] * permille + 999) / 1000;
    ulong seen = 0;
    for (uint i = 0; i < 4097; i++) {
        seen += pause_histogram[i];
        if (seen >= target) return (ulong)i * 10;
    }
    return 40960;
}

macro long gcprof_now() @builtin {
    $if $feat(GC_PROFILE):
        return (long)clock::now();
    $else
        return 0;
    $endif
}

macro void gcprof_phase(uint phase, long* start) @builtin {
    $if $feat(GC_PROFILE):
        long end = (long)clock::now();
        ulong elapsed = (ulong)(end - *start);
        if (phase == 31) {
            ulong bucket = (elapsed + 9999) / 10000;
            if (bucket > 4096) bucket = 4096;
            pause_histogram[bucket]++;
        }
        phase_total[phase] += elapsed;
        phase_count[phase]++;
        if (elapsed > phase_max[phase]) phase_max[phase] = elapsed;
        if (elapsed >= 4_000_000) phase_over_budget[phase]++;
        *start = end;
    $endif
}
