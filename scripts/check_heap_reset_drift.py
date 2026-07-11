#!/usr/bin/env python3
"""
Guard Heap.reset() against field drift.

Parses src/heap.c3 to extract all fields from `struct Heap` and all field
assignments inside `Heap.reset()`.  Any field present in the struct but
absent from reset() is reported as an error — unless it appears in the
ALLOWED_NOT_RESET set (fields intentionally preserved across resets).

Exit 0 = all fields accounted for.  Exit 1 = drift detected.

Usage:
    python3 scripts/check_heap_reset_drift.py          # normal check
    python3 scripts/check_heap_reset_drift.py --show    # print all fields + status

Add this to CI / pre-merge checks so that new Heap fields that forget to
update reset() fail loudly.
"""

import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
HEAP_SRC = os.path.join(PROJECT_DIR, "src", "heap.c3")

# Fields that are intentionally NOT reset — they are set once at heap
# creation and never change, or they are managed by callers (not reset).
# Keep this list minimal and justified.
ALLOWED_NOT_RESET = {
    # ── Allocator callbacks — set at heap::create(), never change ──
    "alloc_func",
    "realloc_func",
    "free_func",
    "heap_udata",
    "fatal_func",

    # ── Immutable after creation ──
    "hash_seed",           # Fixed PRNG seed, set once at heap::create()
    "rnd_state",           # xorshift32 PRNG state, set at creation, evolves

    # ── GC gray stack — capacity/pointer kept; gray_count=0 is sufficient ──
    "gray_objects",        # Pointer kept; gray_count=0 means "empty"
    "gray_capacity",       # Allocation kept; avoids realloc on next use

    # ── Live object counters — informational, reset by GC sweep ──
    "live_obj_count",      # Recomputed by GC sweep, not zeroed in reset
    "peak_live_obj_count", # High-water mark, informational only
    "string_alloc_count",  # Periodic-GC trigger counter, reset by sweep
    "string_sweep_safe",   # Caller-set guard flag, false by default

    # ── VM callbacks — set by vm_create(), not by heap.reset() ──
    "call_handler_fn",     # vm_create sets this
    "call_fn",             # vm_create sets this
    "construct_fn",        # vm_create sets this
    "proxy_get_fn",        # vm_create sets this
    "proxy_has_fn",        # vm_create sets this
    "vm_ptr",              # vm_create sets this (back-pointer to VM)
    "mark_activations_fn", # vm_create sets this

    # ── Microtask queue — allocation/capacity kept; count=0 is sufficient ──
    "microtask_queue",     # TVal* allocation kept, count zeroed
    "microtask_capacity",  # Allocation size kept
    "microtask_after_fn",  # Set by builtins init, not by reset

    # ── Shape system — capacity kept; count/gen reset is sufficient ──
    "shape_capacity",      # Pointer array kept, count zeroed + root recreated
    "trans_count",         # Transition table freed, count implicitly zeroed
    "trans_mask",          # Transition table freed, mask implicitly zeroed

    # ── Module system — allocation kept; counts reset is sufficient ──
    "module_cache_count",  # Growable array kept, count zeroed via free_module_cache
    "module_cache_cap",    # Allocation capacity kept
    "module_cache",        # Set to null inside free_module_cache() (called from reset)

    # ── Generator init stack — depth=0 is sufficient (arrays are garbage) ──
    "gen_init_stack_gs",      # Fixed-size arrays; depth=0 means "empty"
    "gen_init_stack_obj",     # Same
    "gen_init_stack_retval",  # Same

    # ── GC roots array — gc_root_count=0 is sufficient ──
    "gc_roots",            # Fixed-size array; gc_root_count=0 means "empty"

    # ── Compiled function tracking — count reset; cap kept ──
    "compiled_func_cap",   # Allocation capacity kept, count zeroed
}


def extract_struct_fields(text):
    """Extract field names from `struct Heap { ... }`."""
    # Find the struct definition
    m = re.search(r'^struct Heap\s*\{', text, re.MULTILINE)
    if not m:
        print("ERROR: could not find `struct Heap {` in source", file=sys.stderr)
        sys.exit(2)

    start = m.end()
    depth = 1
    i = start
    fields = []

    while i < len(text) and depth > 0:
        c = text[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                break
        i += 1

    struct_body = text[start:i]

    # Match field declarations.  C3 field syntax:
    #   TypeName  field_name;
    #   TypeName* field_name;
    #   TypeName[N] field_name;
    #   TypeName[CONST] field_name;
    # Fields may have doc comments (/// ...) or annotations above them.
    # We match lines that look like:  <type> <name>  (ending with ;)
    # Skip lines that are comments, blank, or contain keywords like fn/struct/enum.
    for line in struct_body.splitlines():
        line = line.strip()
        # Skip comments, blank lines, annotations
        if not line or line.startswith('//') or line.startswith('///'):
            continue
        # Skip lines that are just braces
        if line in ('{', '}'):
            continue
        # Strip inline doc comments BEFORE checking for semicolon —
        # lines like `bool gc_pending;  /// doc` don't end with `;`
        # Also handle `// ModuleDef** — ...` style inline comments
        line = re.sub(r'\s+/{2,}.*$', '', line)
        # Must end with ;
        if not line.endswith(';'):
            continue
        # Remove trailing semicolon
        line = re.sub(r'\s*;.*$', '', line)
        # Split into type and name — last token is the field name
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[-1]
        # Strip array suffixes: field_name[N] → field_name
        name = re.sub(r'\[.*\]$', '', name)
        # Strip pointer prefix: *field_name → field_name (shouldn't happen but be safe)
        name = name.lstrip('*')
        # Validate it looks like an identifier
        if re.match(r'^[a-zA-Z_]\w*$', name):
            fields.append(name)

    return fields


def extract_reset_fields(text):
    """Extract field names assigned inside `Heap.reset()`."""
    # Find the reset method
    m = re.search(r'^fn void Heap\.reset\(&self\)\s*\{', text, re.MULTILINE)
    if not m:
        print("ERROR: could not find `fn void Heap.reset(&self)` in source", file=sys.stderr)
        sys.exit(2)

    start = m.end()
    depth = 1
    i = start
    while i < len(text) and depth > 0:
        c = text[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                break
        i += 1

    reset_body = text[start:i]

    # Find all `self.field_name` assignments: self.field_name = ... or self.field_name[...] = ...
    # Also catch self.field_name++ , self.field_name-- , memset(&self.field_name, ...)
    # Also catch method calls like self.free_module_cache() which implicitly reset fields
    fields = set()

    # Pattern: self.identifier — matches self.field, self.field[i], etc.
    for m in re.finditer(r'self\.(\w+)', reset_body):
        fields.add(m.group(1))

    return fields


def main():
    show_all = '--show' in sys.argv

    with open(HEAP_SRC) as f:
        text = f.read()

    struct_fields = extract_struct_fields(text)
    reset_fields = extract_reset_fields(text)

    # Fields in struct but not in reset()
    missing = []
    for f in struct_fields:
        if f not in reset_fields and f not in ALLOWED_NOT_RESET:
            missing.append(f)

    # Fields in reset() but not in struct (sanity check)
    phantom = []
    for f in reset_fields:
        if f not in struct_fields:
            # Some are sub-fields or method names — skip common false positives
            if f in ('destroy', 'reset', 'free', 'init_builtin_strs',
                     'init_transition_table', 'free_module_cache',
                     'decref_tval', 'hash_string', 'str_table_lookup',
                     'drain_microtasks', 'free_string', 'hobject_free',
                     'shape_free', 'shape_create'):
                continue
            phantom.append(f)

    if show_all:
        print("Heap fields and reset() coverage:")
        for f in struct_fields:
            status = "reset" if f in reset_fields else "allowed" if f in ALLOWED_NOT_RESET else "MISSING"
            print(f"  {f:40s} {status}")
        if phantom:
            print(f"\nPhantom (in reset but not struct): {phantom}")
        print(f"\nTotal struct fields: {len(struct_fields)}")
        print(f"Fields in reset():  {len(reset_fields & set(struct_fields))}")
        print(f"Allowed not reset:  {len(ALLOWED_NOT_RESET)}")
        print(f"Missing (drift):    {len(missing)}")
        sys.exit(1 if missing else 0)

    if missing:
        print("FAIL: Heap.reset() does not touch these struct fields:")
        for f in missing:
            print(f"  - {f}")
        print()
        print("If these are intentionally not reset, add them to ALLOWED_NOT_RESET")
        print(f"in {os.path.relpath(__file__, PROJECT_DIR)}.")
        print("Otherwise, add clearing code to Heap.reset() in src/heap.c3.")
        sys.exit(1)

    print(f"OK: all {len(struct_fields)} Heap fields accounted for in reset()")
    sys.exit(0)


if __name__ == "__main__":
    main()
