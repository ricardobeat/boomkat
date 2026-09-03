# Plan: GC pause reduction from recent collector research

## Status

📝 PLANNED — items ordered by payoff per risk. Each lands separately with
benchmarks before commit.

## Context

The engine pairs reference counting with a stop-the-world mark-sweep backup
for cycles (`src/heap.c3`: `mark_and_sweep`, `drain_gray`, `sweep`,
`sweep_strings`). The shape-exhaustion fix (linear key marking in
`drain_gray`) removed one quadratic pause source. What remains is structural:
every cycle walks the whole heap three times (clear flags, sweep, clear
survivors), sweeps eagerly in one pause, and re-marks the entire live set
even when little changed. The user directive is explicit: tolerate sloppy
reclamation in exchange for shorter pauses.

Sources surveyed: Nofl/Immix (Wingo, ISMM 2025), CRuby and Julia GC reworks
(ISMM 2025), lifetime dispersion vs the generational hypothesis (Dolan, ISMM
2025), V8 Maps/DescriptorArray/NormalizeProperties, MMTk-as-library,
Arborescent cycle collection, single-pass compaction.

Rejected for this engine: MMTk integration, moving compactors, cycle forests,
serialized heaps, PIM designs. Each fights the raw-pointer plus pool layout
or exceeds what low-power targets can carry. Refcounting plus a backup
tracer already covers cycles.

## Item 1: mark epoch instead of clear passes

Each cycle scans `heap_allocated` to clear reachable flags, then scans it
twice more in `sweep` (unlink dying, clear survivors), plus a full string
table clear. Replace the boolean with a `current_mark` generation: marking
stamps the epoch, and "clear" becomes a counter bump. Pure pause win, no
reclamation change, smallest diff of the four.

Validation: engine suite 114/0, benches at parity, plus a run that forces
several cycles over a large live set with no survivor loss.

## Item 2: lazy sweep in bounded chunks

`sweep` unlinks, tears down, and frees every dying node in one pause. Thread
the dying list and release it in bounded chunks at later safepoints or
allocation points. Directly matches the sloppy-over-pauses directive:
floating garbage grows slightly, worst-case pause shrinks a lot. Nofl's lazy
sweeping is the reference; only the chunking idea transfers, not Immix
itself.

Validation: same suites plus a pause-oriented check (max per-cycle sweep
time on a garbage-heavy workload goes down while total freed stays equal).

## Item 3: dictionary-mode cap for deep chains

Marking is linear now, but lookup and hash-rebuild paths still walk O(depth)
shape chains. Past a threshold (V8 normalizes; ~128 properties is the
starting point to measure), flatten the object to a private dictionary shape
instead of extending the chain. Kills the whole class of deep-chain cliffs
rather than patching each walker.

Validation: deep-object microbenchmarks (reads, writes, deletes past the
threshold stay flat), engine suite, benches. Threshold tuned by measurement,
not fixed upfront.

## Item 4: sticky-mark nursery via the existing write barrier

Every cycle re-marks the whole live set. Skip objects that survived N cycles
unless dirtied inputs, and `track_heap_store` already provides the barrier
for the remembered set. Most invasive of the four: root scanning and the
barrier protocol both change, so it lands last when the pause floor from
items 1–3 is known.

Validation: same suites plus a steady-state workload (long-lived heap with
small per-iteration churn) showing fewer marks per cycle with no leaks under
`just test-gc-stress`.
