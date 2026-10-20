#!/usr/bin/env python3
"""
Guard Heap.reset() against field drift.

Parses src/heap.c3 to extract all fields from `struct Heap` and field
references inside `Heap.reset()` and its audited cleanup helpers. Any field
absent from that cleanup is reported as an error — unless it appears in the
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

# Fields intentionally preserved, or initialized by the next VM.
# Keep this list minimal and justified.
ALLOWED_NOT_RESET = {
    # ── Allocator callbacks — set at heap::create(), never change ──
    "alloc_func",
    "realloc_func",
    "free_func",
    "heap_udata",
    "fatal_func",

    # ── Heap configuration and PRNG state ──
    "hash_seed",           # Fixed PRNG seed, set once at heap::create()
    "rnd_state",           # xorshift32 PRNG state, set at creation, evolves

    "mem_limit",          # Host-selected memory limit survives reset
    "string_sweep_safe",   # Caller-set guard flag, false by default

    # ── VM callbacks — set by vm_create(), not by heap.reset() ──
    "call_handler_fn",     # vm_create sets this
    "call_fn",             # vm_create sets this
    "construct_fn",        # vm_create sets this
    "proxy_get_fn",        # vm_create sets this
    "force_deferred_ns_fn", # vm_create sets this
    "proxy_has_fn",        # vm_create sets this
    "vm_ptr",              # vm_create sets this (back-pointer to VM)
    "mark_activations_fn", # vm_create sets this
    "mark_activations_slice_fn", # vm_create sets this
    "catcher_chain_fn",    # vm_create sets this

    # ── Host reporting callback, installed by the CLI / embedding host ──
    "rejection_tracker_fn",
    "rejection_tracker_udata",

    # ── Microtask callback — installed by builtins init ──
    "microtask_after_fn",  # Set by builtins init, not by reset

    # ── Host arrays — backing storage kept; live counts reset ──
    "host_fns",
    "host_fn_capacity",
    "host_classes",
    "host_class_capacity",
    "addon_handle_capacity",
    "host_scopes",
    "host_scope_capacity",
    "host_vals_capacity",
    "host_scope_generation", # Monotonic so stale host handles stay invalid

    # ── Join recursion stack — backing storage kept; count reset ──
    "join_visited",
    "join_visited_capacity",

    # ── Generator init stack — depth=0 is sufficient (arrays are garbage) ──
    "gen_init_stack_gs",      # Fixed-size arrays; depth=0 means "empty"
    "gen_init_stack_obj",     # Same
    "gen_init_stack_retval",  # Same

    # ── Compiled function tracking — count reset; cap kept ──
    "compiled_func_cap",   # Allocation capacity kept, count zeroed
    "compiled_funcs",      # Backing array kept, count zeroed via compiled_func_count=0

    # ── Large string registry — count reset; cap kept ──
    "large_string_capacity", # Allocation capacity kept, count zeroed
}


def source_code(text):
    """Hide comments and literals so their braces/references cannot count."""
    return re.sub(
        r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
        lambda m: re.sub(r'[^\n]', ' ', m.group()), text, flags=re.DOTALL,
    )


def extract_body(text, declaration):
    text = source_code(text)
    m = re.search(declaration + r'\s*\{', text, re.MULTILINE)
    if not m:
        raise ValueError(f"could not find declaration: {declaration}")
    start = m.end()
    depth = 1
    for i in range(start, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[start:i]
    raise ValueError(f"unclosed declaration: {declaration}")


# Only follow audited cleanup edges. Following arbitrary methods would count
# unrelated initialization or GC references as reset coverage.
# call: (source path, function name, heap parameter)
RESET_HELPERS = {
    "self.drain_catcher_pool()": ("src/heap.c3", "Heap.drain_catcher_pool", "self"),
    "self.free_module_cache()": ("src/heap.c3", "Heap.free_module_cache", "self"),
    "self.init_transition_table()": ("src/heap.c3", "Heap.init_transition_table", "self"),
    "hobject::env_pool_teardown(self)": ("src/hobject.c3", "env_pool_teardown", "h"),
    "env::env_pool_teardown(h)": ("src/env.c3", "env_pool_teardown", "h"),
    "esm::free_defined_modules(self)": ("src/module.c3", "free_defined_modules", "heap"),
}


def extract_struct_fields(text):
    """Extract field names from `struct Heap { ... }`."""
    struct_body = extract_body(text, r'^struct Heap')
    fields = []

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


def extract_reset_fields(text, sources=None):
    """Collect field references along the audited reset cleanup paths."""
    sources = dict(sources or {})
    sources["src/heap.c3"] = text
    visited = set()

    def visit(path, name, receiver):
        key = (path, name, receiver)
        if key in visited:
            return set()
        visited.add(key)
        if path not in sources:
            with open(os.path.join(PROJECT_DIR, path)) as f:
                sources[path] = f.read()
        body = extract_body(sources[path], rf'^fn void {re.escape(name)}\([^)]*\)')
        fields = set(re.findall(rf'\b{re.escape(receiver)}\.(\w+)', body))
        calls = re.sub(r'\s+', '', body)
        for call, helper in RESET_HELPERS.items():
            if call in calls:
                fields.update(visit(*helper))
        return fields

    return visit("src/heap.c3", "Heap.reset", "self")


def main():
    show_all = '--show' in sys.argv

    with open(HEAP_SRC) as f:
        text = f.read()

    try:
        struct_fields = extract_struct_fields(text)
        reset_fields = extract_reset_fields(text)
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(2)

    # Fields in struct but not in reset()
    missing = []
    for f in struct_fields:
        if f not in reset_fields and f not in ALLOWED_NOT_RESET:
            missing.append(f)

    if show_all:
        print("Heap fields and reset() coverage:")
        for f in struct_fields:
            status = "reset" if f in reset_fields else "allowed" if f in ALLOWED_NOT_RESET else "MISSING"
            print(f"  {f:40s} {status}")
        print(f"\nTotal struct fields: {len(struct_fields)}")
        print(f"Fields in reset():  {len(reset_fields & set(struct_fields))}")
        print(f"Allowed not reset:  {len((ALLOWED_NOT_RESET & set(struct_fields)) - reset_fields)}")
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
