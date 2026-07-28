# String representation survey: fixing O(n) character indexing

Status: research / design survey. No code changed. All measurements in this
document were taken on the author's machine (darwin, aarch64) against
`out/duktape_c3` at commit `e53cb15`, unless marked otherwise.

---

## 1. Problem statement

All engine strings are stored as **CESU-8** (`src/hstring.c3`, comment block
at ~line 513): every UTF-16 code unit gets its own independent 1–3 byte UTF-8
sequence, astral codepoints split into a surrogate pair first. This makes byte
storage compact and keeps ASCII a 1-byte-per-unit fast path, but it makes the
mapping from a JS character index (a UTF-16 code unit index) to a byte offset a
**variable-width problem**: you must walk sequences from byte 0.

`HString.char_at` (~line 251) and `HString.char_offset_to_byte_offset`
(~line 283) both have an `is_ascii` O(1) fast path and an O(n) walk otherwise.
On an 8k-code-unit non-ASCII string, 2000 operations (duktape-c3 vs vendored
`./quickjs/qjs`):

| op | duktape-c3 | qjs |
|---|---|---|
| charAt | 16.8 ms | 0.0 ms |
| charCodeAt | 16.8 ms | 0.0 ms |
| slice | 10.1 ms | 0.0 ms |
| substring | 10.0 ms | 1.0 ms |
| indexOf | 26.1 ms | 8.0 ms |
| charAt (ASCII) | 0.1 ms | 0.0 ms |

I reproduced this independently (`s.charCodeAt(i%8192)` on 8192 `é`):
**17.3 ms vs qjs 0 ms**. The cost scales cleanly linearly with string length,
confirming O(n):

| string length (code units) | duktape-c3 | qjs |
|---|---|---|
| 64 | 0.33 ms | 0 ms |
| 256 | 0.88 ms | 0 ms |
| 1024 | 3.90 ms | 0 ms |
| 4096 | 10.39 ms | 0 ms |
| 16384 | 33.06 ms | 0 ms |

Encoding width matters (denser encodings mean more bytes to walk per unit):
8192-unit strings of Latin-1 accented (2-byte), CJK (3-byte), and emoji
(astral, 2×3-byte) cost **17.3 / 25.3 / 27.0 ms** respectively.

### Three findings not in the original problem framing

These materially change the analysis, so they are stated up front.

**(a) `.length` is itself O(n), and it is on the hot path of every indexing
operation.** `HString.char_length()` (line 226) has no cached value — for
non-ASCII it calls `compute_charlen()`, a full walk, *every time*. It is called
**75 times** across the codebase. Measured: 2000 reads of `s.length` on the 8k
non-ASCII string cost **6.9 ms** on its own (qjs: 1 ms).

Worse, `char_at` *begins* with `if (char_idx >= self.char_length())`. So
`charCodeAt` walks the string **twice** — once for the bounds check, once for
the index — and `builtin_string_proto_charCodeAt`
(`src/builtins/string.c3:518`) computes `clen` a *third* time before calling
`char_at`. About half the measured charCodeAt cost is the redundant length
walks, not the index walk.

**Caching charlen in the HString header is a prerequisite for every other
option in this document, and is independently worth roughly half the current
cost.** Duktape itself does this (`clen`/`clen16` fields in `duk_hstring.h`);
this codebase dropped the field. This is the single highest
value-per-unit-of-risk change available.

**(b) Bracket indexing `s[i]` hits the same path.** `char_at` is called from
`src/vm/vm_property.c3` at lines 271, 446, and 674, so the most idiomatic
access pattern in JS is equally slow. Measured: `s[i%8192]` = **17.6 ms**.
The string-exotic `has_property` path (`src/hobject.c3:2653`) calls
`char_length()` too, so even *probing* `s[i]` is an O(n) walk.

**(c) The "everything is interned" constraint is already weaker than stated.**
`Heap.str_intern_normalized` (`src/heap.c3:3242`) does **not** intern strings
longer than `MAX_INTERN_BYTES` (256 bytes) — they are heap-allocated,
non-interned, registered in the large-string registry, and freed by
refcounting. `HString.equals_hstring` (`src/hstring.c3:165`) already handles
this: if *either* side is non-interned it falls back to length + hash +
`memcmp`. The VM's `SEQ`/`SNEQ` (`src/vm/vm_execute.c3:2389,2435,2582`) and
`src/vm/vm_eq.c3:143` all go through `equals_hstring`.

This matters enormously: **the strings that are slow (large, non-ASCII) are
precisely the strings that are already not interned.** Any per-string side
data attached only to large strings therefore cannot break pointer-identity
equality, because pointer identity is already not the equality rule for them.
This removes the single most dangerous risk from the per-string-index designs.

---

## 2. Comparison table

"Migration size" is my estimate of the diff in this codebase. Call-site counts:
`char_offset_to_byte_offset` = 29, `char_at` = 56, `char_length()` = 75, across
15 files.

| Design | Random access | Sequential | Memory overhead | Interning-safe? | Kills regexp conversion? | Migration size |
|---|---|---|---|---|---|---|
| **0. Cache `charlen` in header** | still O(n) | still O(n) | +0–4 B/string | Yes (no repr change) | No | ~20 lines |
| **1. Heap cursor cache (Duktape)** | **O(n)** — no help | **O(1) amortised** | 16 B × 4 global | Yes | No | ~80 lines |
| **2. Per-string breadcrumbs (Swift)** | **O(stride)**, ~stride/2 walk | O(1) | 4 B per `stride` units (~3% at stride 64) | Yes (large strings already non-interned) | No | ~150 lines |
| **3. Fixed-width Latin-1/UTF-16 (QuickJS/V8/JSC/SM/Python)** | **O(1)** true | O(1) | +100% for BMP non-Latin-1; −0% ASCII | Yes | **Yes** | **Very large** — touches all 160 call sites + every byte-level consumer |
| **4. SIMD walk (NEON/SSE)** | O(n) but ~30× faster | O(n)/30 | 0 | Yes | No | ~60 lines |
| **5. Succinct rank/select bitvector** | O(1) true | O(1) | +25–40% of *bit* length, plus select overhead | Yes | No | Large, high complexity |
| **6. Ropes (QuickJS `JSStringRope`)** | O(depth) then O(n) | — | pointer pair per node | **Only via linearize-before-intern** | No | Large; solves concat, *not* indexing |
| **7. Chunked fixed-width segments** | O(1) after chunk lookup | O(1) | variable | Yes | Partially | Large |

---

## 2b. What every engine actually does (survey summary)

The central finding from surveying nine engines: **no production JS engine
achieves both variable-width byte storage and O(1) `charAt`. It is a forced
choice.** Engines either store fixed-width units and index by shift, or store
variable-width bytes and pay an O(n) walk mitigated by an anchor cache.

| Engine | Storage | index → code unit |
|---|---|---|
| **JerryScript** | **CESU-8** | Walk from byte 0. **No cache at all.** `size == length` ASCII test is the only fast path |
| **Duktape** | WTF-8 (master) | Walk, with a **4-entry weak anchor cache** — the reference mitigation |
| **XS/Moddable** | UTF-8 | Walk; cache exists but **defaults to off**; ships non-conformant `length` by default |
| **V8** | Latin-1 / UTF-16 | O(1) on flat; `ConsString::Get` walks O(depth), does not flatten |
| **JavaScriptCore** | Latin-1 / UTF-16 | `at()` unconditionally O(1); ropes must `resolveRope` first |
| **SpiderMonkey** | Latin-1 / UTF-16 | O(1); one-level rope fast path then `ensureLinear` |
| **Hermes** | ASCII / UTF-16 | O(1); **no ropes exist at all** |
| **Boa** (Rust) | latin1 / utf16 | O(1) slice index |
| **Espruino** | byte chain | **O(n) per call, no cache** — `for(i) s[i]` is O(n²) |

Two observations that bear on the recommendation:

- **JerryScript is this codebase's closest architectural sibling** — CESU-8
  storage, small-footprint target — and it simply eats the walk. So the current
  behaviour is not an aberration; it is what the nearest comparable engine
  does. But that also means matching JerryScript is a *low bar*. **Duktape is
  the better target**, and it is already vendored here for reference.
- **Do not follow XS in redefining `length` to count code points.** It is
  tempting (it would make `length` O(1)-ish) and it visibly breaks conformance.
  Finding (a) — caching the code-unit count — gets the same speed with no
  spec violation.

Outside JS: the runtimes that keep UTF-8 in memory (Go, Rust, Elixir, Julia)
all *decline* to offer O(1) character indexing, and Rust and Julia say so
explicitly in their docs — Rust: *"indexing operations are expected to always
take constant time (O(1)). But it isn't possible to guarantee that performance
with a String, because Rust would have to walk through the contents from the
beginning."* Julia: character indexing *"cannot be implemented both efficiently
and simply for variable-width encodings."* The runtimes that *do* offer O(1)
(Python kinds, Java's `coder`, Raku's 32-bit graphemes) all buy it by making
characters fixed-width. **Swift is the only production system with this
codebase's exact constraint — UTF-8 native, must expose UTF-16 indices — and it
chose breadcrumbs, not a succinct structure.** That is the strongest single
argument for design 2.

---

## 3. Candidate designs

### 0. Cache `charlen` in the HString header (baseline prerequisite)

**What it is.** Add a `uint clen` field (or reuse spare flag bits) to
`HString`, computed once at `hstring_alloc` time or lazily on first
`char_length()` call, and make `char_length()` return it.

Duktape does exactly this. `duk_hstring.h` carries `clen16` (16-bit variant for
low-memory builds) or `clen` (32-bit), with
`DUK_HSTRING_GET_CHARLEN(x) -> duk_hstring_get_charlen(x)` and an explicit
`duk_hstring_init_charlen`. Note Duktape's `DUK_HSTRING_FLAG_ASCII` is
documented as "lazily set!" — they compute it on demand rather than at alloc.

**Complexity.** Doesn't change indexing complexity at all. Removes the
*separate* O(n) length walk, which is currently ~40–50% of `charCodeAt` cost
and 100% of `.length` cost.

**Memory.** The current header is 24 bytes: `flags`(4) + `refcount`(4) +
`registry_slot`(8) + `hash`(4) + `blen`(4). Adding `uint clen` makes it 28,
which on 8-byte alignment rounds to **32 bytes — a 33% header growth**. That is
real for a heap full of short property-key strings.

Two ways to avoid paying it:
- Only ASCII strings are common and for them `clen == blen`, so store `clen`
  *only* for non-ASCII strings, in the side table proposed in design 2. Costs
  nothing for the common case.
- Or note that `registry_slot` is `usz` (8 bytes) and documented as
  "Sized as a pointer purely to keep the header 8-byte aligned" — it holds a
  slot index, not a pointer. If slot indices fit in 32 bits, `registry_slot`
  can become `uint` and `clen` occupies the freed 4 bytes, making this
  **completely free**. This should be checked first.

**Downsides.** Almost none. Small correctness surface: the field must be
invalidated nowhere (strings are immutable), so it is write-once.

**Verdict: do this regardless of what else is chosen.**

---

### 1. Heap-level cursor cache (Duktape's `duk_strcache`)

**What it is.** Ground truth read from
`duktape/duktape/src-separate/duk_heap_stringcache.c` and `duk_heap.h`.

```c
struct duk_strcache_entry {
    duk_hstring *h;
    duk_uint32_t bidx;   /* byte offset */
    duk_uint32_t cidx;   /* char offset */
};
```
`#define DUK_HEAP_STRCACHE_SIZE 4` — a fixed 4-entry array on the *heap*
(`duk_strcache_entry strcache[4]`), not per-string. Entries are **weak
references**: `duk_heap_strcache_string_remove` is called at string
finalization to null out dangling `h` pointers.

`duk_heap_strcache_offset_char2byte` logic:
1. If `DUK_HSTRING_IS_ASCII(h)` → return `char_offset` directly.
2. `use_cache = (char_length > DUK_HEAP_STRINGCACHE_NOCACHE_LIMIT)` where the
   limit is **16** — short strings never touch the cache, deliberately, so they
   don't evict a more valuable entry.
3. Linear scan of the 4 entries for `c->h == h`.
4. Compute three distances — `dist_start = char_offset`,
   `dist_end = char_length - char_offset`, `dist_sce = |char_offset - sce->cidx|`
   — and **scan from whichever of {string start, string end, cache entry} is
   nearest**, forwards or backwards. `duk__scan_backwards` works because
   continuation bytes are identifiable in isolation (`(*p & 0xc0) != 0x80`).
5. Update the entry (LRU-ish, moved to front).

**Complexity.** Sequential access becomes **O(1) amortised** — this is what it
is designed for, and it is very good at it. Random access is **not improved**:
`dist_sce` for a random index averages n/3, so you still walk O(n).
Bidirectional scanning + scan-from-end caps the worst case at n/2 rather than
n, a constant-factor 2× at best.

**Measured** (my C microbenchmark, `scratchpad/bench2.c`, 8192-unit 2-byte
string, 2000 ops):

| access pattern | cursor cache |
|---|---|
| sequential | **0.0095 ms** |
| random | **5.34 ms** |

Compare the O(n) walk baseline at ~27 ms for random. So the cursor cache is a
**5× win on random** (from the scan-from-nearest-end trick) and a **~2800× win
on sequential**.

**Memory.** 4 × 16 B = 64 bytes total, globally. Essentially free.

**Interning-safe?** Completely — no representation change, side data only.

**Downsides.** Random access still O(n). Also, the weak-reference bookkeeping
must be wired into string free paths or you get use-after-free — this is real
but contained (Duktape's `duk_heap_strcache_string_remove` is 15 lines).

**Who ships it.** Duktape, in production, and it is the reason Duktape's
sequential string scans are acceptable despite UTF-8 storage.

---

### 2. Per-string breadcrumbs (Swift's mechanism) — *recommended*

**What it is.** Swift's `String` is UTF-8-native but must expose O(1)-ish
UTF-16 indexing for ObjC/`NSString` bridging — **exactly this problem**.
Swift's answer is `_StringBreadcrumbs`: a lazily-built, atomically-installed
side object holding an array of `String.Index` values sampled every *stride*
UTF-16 code units. A UTF-16 offset lookup divides by the stride to index the
array directly, then linearly scans at most *stride* units from there.

The transplant here: for a non-ASCII `HString`, store a small array of `uint`
byte offsets, one per `STRIDE` code units. Then:

```
byte_offset(ci):
    k  = ci / STRIDE          // direct index, no search
    bo = table[k]
    cur = k * STRIDE
    while (cur < ci) { bo += utf8_seq_len(data[bo]); cur++; }   // <= STRIDE steps
    return bo
```

Because the table is indexed by *character* count (not byte count), the lookup
is a **direct array index, not a binary search** — this is the key design
choice, and it makes the operation O(STRIDE), i.e. O(1) with a tunable
constant. Indexing every N *bytes* instead would require a binary search over
cumulative counts, O(log n), and is strictly worse here.

**Measured** (`scratchpad/bench2.c`, 8192-unit 2-byte string, 2000 ops,
including a stride sweep):

| stride | table size for 16 KB string | overhead | random access | build cost |
|---|---|---|---|---|
| 16 | 2052 B | 12.5% | **0.030 ms** | 30.3 µs |
| 32 | 1028 B | 6.3% | **0.083 ms** | 28.9 µs |
| 64 | 516 B | 3.1% | **0.162 ms** | 27.9 µs |
| 128 | 260 B | 1.6% | **0.398 ms** | 28.6 µs |
| 256 | 132 B | 0.8% | **0.856 ms** | 28.5 µs |

Baseline O(n) walk: **27.6 ms**. Fixed-width UTF-16 array index: **0.0004 ms**.

So **stride 64 gives a 170× speedup on random access for 3.1% memory
overhead**, and unlike the cursor cache it is equally fast for random and
sequential (0.162 vs 0.165 ms — a flat profile, no access-pattern cliff).
Stride 32 gives 330× for 6.3%.

Build cost is ~28 µs for an 8k string, i.e. roughly one full O(n) walk —
so it pays for itself after the *second* indexed access. Build lazily, on
first indexed access, never at allocation time.

**Complexity.** Random **O(STRIDE)**, sequential **O(STRIDE)** (or O(1) if
combined with a cursor). Memory `4 × ceil(clen/STRIDE)` bytes, only for
non-ASCII strings that are actually indexed.

**Interning-safe?** **Yes**, and this is the crucial point from finding (c).
The table is *side data attached to an existing HString*, not a different
representation of the string — the bytes, the hash, and the pointer are all
unchanged, so `===`, the string table, and property lookup are entirely
untouched. Two logically-equal strings cannot become two objects because of
it. This is categorically safer than ropes.

**Where to put the table.** Three options, in increasing intrusiveness:
1. **A heap-side hash map** `HString* -> table`, with weak entries cleared on
   string free (same discipline as Duktape's strcache, which already must be
   built for design 1). Zero header growth. Costs a hash lookup per access —
   at 170× headroom this is affordable.
2. **A pointer field in the header**, only meaningful when `!is_ascii`.
   Costs 8 bytes per string, which is a 33% header growth — bad for the many
   short ASCII strings.
3. **Inline, allocated past the NUL terminator**, since strings are already
   one contiguous allocation. Elegant and cache-friendly, but strings are
   immutable and already allocated by the time you know you want a table, so
   this only works if built eagerly at alloc time — which wastes the build cost
   on strings never indexed. Not recommended.

Option 1 is the right starting point: it composes with the cursor cache
(the same weak-reference machinery serves both) and adds nothing to the header.

**Threshold.** Only build for strings above some `clen` — the measurements
show a 64-unit string already costs 0.33 ms/2000 ops, but the table would be
1 entry; a threshold around 128–256 code units mirrors Duktape's NOCACHE_LIMIT
reasoning and keeps the map small.

**Downsides.** Extra allocation per indexed large string. Weak-reference
bookkeeping (shared with design 1). Does not help the regexp conversion. Does
not make access truly O(1) — but 170× at 3% memory is an excellent point on the
curve.

**Who ships it.** Swift's standard library, in production, for precisely the
UTF-8-storage/UTF-16-index mismatch.

**Verified against Swift source** (`stdlib/public/core/StringBreadcrumbs.swift`,
`StringGuts.swift`, `StringUTF16View.swift`). Swift independently chose
**stride 64**, matching my measured sweep above — arrived at from two
directions, which is reassuring. Details worth copying:

- **Per crumb: a packed `UInt32`, not a full index.** Swift's comment: encoding
  one takes up to 49 bits (48-bit byte offset + trailing-surrogate bit), *"but
  for any String shorter than 2^31 bytes it fits in a 32 bit `_PackedCrumb`"* —
  `(byteOffset << 1) | trailingSurrogateBit`. Our `uint` table is the same
  shape; we don't need the surrogate bit since CESU-8 stores each half
  separately.
- **The two lookup directions have different costs.** UTF-16 offset → index
  (*our* direction) is `(crumbs[offset / stride], offset % stride)` — a direct
  index, **no search**, exactly as designed above. The *reverse* (index →
  offset) needs a bounded binary search. We only need the fast direction.
- **ASCII bypasses the table entirely** (`if _guts.isASCII { return
  Index(_encodedOffset: offset) }`). Our existing `is_ascii` flag already gives
  us this.
- **The "one crumb" trick**: when a string needs only one crumb, Swift stores
  the UTF-16 *count* in the breadcrumbs pointer slot itself. That is a neat way
  to get finding (a) — cached charlen — for free on short strings without
  growing the header, and is worth considering for the side-map design.
- **Don't consult the table for short hops**: Swift skips breadcrumbs when the
  offset delta is under one stride. Cheap guard, worth having.
- **Atomic install**: `_stdlib_atomicAcquiringInitializeARCRef`, losing racers
  discard their copy. Single-threaded here, so this simplifies away — but note
  the vectorized builder is *"~3x faster than the scalar version it replaced"*,
  reinforcing the SIMD-assisted-build point in design 4.
- A standing `FIXME` in Swift's own source notes both paths always scan up from
  the lower crumb, and that *"starting from the upper-bound crumb when that is
  closer would cut the average cost of the subsequent iteration by 50%"* — a
  free 2× we can take from the start by scanning from the nearer end.

Memory: 4 bytes per 64 UTF-16 units is asymptotically 6.25% of a 1-byte/unit
string, **3.13% at 2 bytes/unit** — matching my measured 3.1% exactly.

---

### 3. Fixed-width Latin-1 / UTF-16 storage (the QuickJS answer)

**What it is.** Ground truth from `quickjs/quickjs.c:575`:

```c
struct JSString {
    uint32_t len : 31;
    uint8_t is_wide_char : 1;   /* 0 = 8 bits, 1 = 16 bits characters */
    uint32_t hash : 30;
    uint8_t atom_type : 2;      /* != 0 if atom */
    uint32_t hash_next;
    union {
        uint8_t  str8[0];       /* 8 bit strings get an extra null terminator */
        uint16_t str16[0];
    } u;
};
```

One bit selects the width; indexing is `p->u.str8[i]` or `p->u.str16[i]` — a
single array index, unconditionally O(1). Strings that are entirely
Latin-1 (≤ U+00FF) pay 1 byte/unit; anything else pays 2 bytes/unit flat,
*including* ASCII characters inside a mostly-ASCII string with one accent.

This is the mainstream answer. V8 (`SeqOneByteString`/`SeqTwoByteString`),
JavaScriptCore (`StringImpl` with an `is8Bit()` flag), SpiderMonkey (latin1 vs
twoByte), and CPython's PEP 393 (latin1/UCS2/UCS4 chosen per string) all use
the same "pick the narrowest fixed width that fits" strategy. It is
overwhelmingly the industry consensus, and the reason qjs shows 0 ms.

**JavaScriptCore's variant, verified against WTF headers**, is worth a closer
look because two of its tricks are cheap to steal independently of any
migration:

- `WTF::StringImpl::at()` is unconditionally O(1):
  `is8Bit() ? span8()[i] : span16()[i]`. There is no rope concept at the WTF
  layer at all — ropes live one level up in `JSRopeString` and must be
  resolved (`resolveRope`) before any indexed read. Same "flatten once, then
  index O(1)" shape as V8.
- **Flag bits live in pointer alignment bits.** `isRopeInPointer == 0b001`,
  `isSubstringInPointer == 0b010`, `is8BitInPointer == 0b100`, so a plain
  non-rope `JSString` is literally a tagged `StringImpl*` with *zero* flag
  bits set, and `isRope()` is `m_fiber & 1`. Encoding the common case as
  all-zeros is the same instinct as V8's `kInternalizedTag == 0`.
- **One refcount bit buys immortality**: `s_refCountFlagIsStaticString = 0x1`
  with `s_refCountIncrement = 0x2`, so static strings never reach zero without
  a branch in the hot ref/deref path. Directly applicable here — this codebase
  has permanent builtin strings that currently pay ordinary refcount traffic.
- **No `ThinString` equivalent is needed.** Atomization flips a flag in place
  on the existing impl, because `StringImpl` is refcounted and immovable
  rather than GC-moved. V8 needs `MakeThin` precisely because its objects
  move. This codebase's strings are also immovable, so it inherits JSC's
  simpler position for free.
- JSC materializes the data pointer (8 bytes/string) instead of computing it
  from the object address the way V8 and this codebase do. That is a
  footprint-versus-branch tradeoff, and for a small-footprint target the
  current compute-from-address approach is the better side of it.

One correction to a widespread belief, since it bears directly on the interning
constraint: **`JSString::equalInline` has no pointer-identity fast path.** It
always compares content, calling `view()` on both operands. JSC exploits atom
identity at property-lookup *use sites*, not in general string equality — i.e.
even an engine with atoms does not necessarily make `===` a pointer compare.
That is a reminder that the identity invariant in this codebase is a local
design choice worth preserving deliberately, not an inevitability.

**Complexity.** Random O(1), sequential O(1), truly. No side data, no lazy
build, no cache invalidation, no weak references. Conceptually the *simplest*
end state, which is why everyone converged on it.

**Memory.** For ASCII: identical to today (1 B/unit). For a string with any
non-Latin-1 character: **+100%** vs CESU-8 for CJK (3 bytes → 2 bytes is
actually a *saving* of 33% for pure CJK!), but +100% for a mostly-ASCII string
containing one CJK character. Roughly: CESU-8 wins on mixed ASCII+occasional
non-ASCII; UTF-16 wins on dense CJK. For Latin-1 accented text (2 bytes CESU-8
→ 1 byte Latin-1) it is a **50% saving**.

**Kills the regexp conversion?** **Yes — this is its unique advantage.**
`libregexp/re_wrapper.c` currently does, on *every* non-ASCII `re_exec` call
(lines 182–202, 280): `cesu8_to_utf16()` mallocs `2*(input_len+1)` bytes for
units **plus** `4*(input_len+1)` bytes for a byte-offset table, transcodes the
whole input, runs the match, then maps every capture offset back through
`unit_offset_to_byte_offset` and frees both. That is **6 bytes of allocation
and a full transcode per input byte, per exec**, and it is why indexOf/regexp
show 26.1 ms. With native UTF-16 storage the buffer would be passed to
`lre_exec` directly with `cbuf_type = 1` and zero copying — deleting
`cesu8_to_utf16`, `unit_offset_to_byte_offset`, and both mallocs outright.
The ASCII fast path at line 247 (`cbuf_type = 0`, no transcode) already
demonstrates exactly this, and is explicitly commented "This is what QuickJS
does for its 8-bit strings."

**Interning-safe?** Yes — it is a storage change, not an identity change.
Note it would also let `normalize_to_cesu8` disappear, since UTF-16 code units
have exactly one representation, removing a whole class of "same string, two
encodings" interning bugs that `str_intern` currently spends a scan defending
against.

**Downsides — and they are the decisive ones.**
- **Migration cost is very large.** 160 call sites (`char_at` 56,
  `char_offset_to_byte_offset` 29, `char_length` 75) across 15 files, but that
  undercounts the real work: *every* consumer that treats the buffer as bytes
  must change. `get_cstr()` returning a NUL-terminated `char*` for C interop
  is load-bearing and breaks for wide strings (a UTF-16 buffer has interior
  NUL bytes for every ASCII character). `hstring_compare` does a raw byte
  compare — correct for CESU-8 code-point ordering, wrong across a
  narrow/wide boundary. `hash_string` (FNV-1a over raw bytes) must produce the
  same hash for the same logical string regardless of width, or interning
  breaks — so hashing must be defined over code units, not bytes, and every
  precomputed/bootstrap hash changes.
- `dtoa_wrapper.c`, `date_math.c`, the lexer, and anything calling
  `get_cstr()` all assume byte storage.
- Two representations means every accessor grows a branch, which partly
  eats the benefit for ASCII (though a well-placed `is_wide_char` check is far
  cheaper than a walk).

This is a multi-week, high-regression-risk migration. It is the *right* long
term answer and the wrong *next* step.

---

### 4. SIMD-accelerated walk

**What it is.** Keep CESU-8 and keep the O(n) walk, but make the walk 30×
faster by counting non-continuation bytes (`(b & 0xC0) != 0x80`) 16 bytes at a
time. To find the byte offset of the i-th code unit: scan blocks, popcount
lead bytes per block, skip whole blocks while the running count is below i,
then scalar-scan the final block.

**Measured** (my NEON implementation, `scratchpad/scan.c`, same machine):

- Full-buffer lead-byte count over 16384 bytes: **914 ns → 17.9 GB/s**
- The 2000-random-op workload: **0.93 ms** vs 27.6 ms scalar — a **30×
  speedup**.

Deriving the acceptability threshold: at 17.9 GB/s, an O(n) scan stays under
100 ns for strings up to roughly **1.8 KB**. Under 1 µs up to ~18 KB. So SIMD
alone makes strings up to a couple of KB effectively free, and merely tolerable
beyond that — it moves the cliff out by ~30×, it does not remove it.

**Complexity.** Still O(n), with a ~30× smaller constant. Memory overhead
**zero**. Random and sequential identical.

**Interning-safe?** Yes, completely — pure computation, no state.

**Downsides.** Needs per-architecture code (NEON + SSE2/AVX2 + scalar
fallback), which conflicts somewhat with the "small footprint" goal. Doesn't
help the regexp conversion. And it is strictly dominated by breadcrumbs on
speed (0.93 ms vs 0.16 ms) while being *more* portable-code effort — though it
composes well: SIMD makes the *breadcrumb build* ~30× cheaper (28 µs → ~1 µs),
which is a genuinely attractive combination.

**Who ships it.** `simdutf` (used by Node.js and Bun) exposes exactly this
primitive as **`utf16_length_from_utf8`**. The Rust `str_indices` crate ships
the same idiom with three backends — `__m128i` (x86-64), `uint8x16_t`
(aarch64), and SWAR only as a portable fallback:

```rust
fn is_leading_byte(b: &u8) -> bool { (b & 0xC0) != 0x80 }
// chunk-wise: val.bitand(splat(0xC0)).cmp_eq_byte(0x80)  — count CONTINUATION bytes, then len - count
```

Two implementation notes that transfer directly:

- **`str_indices::to_byte_idx` is precisely the "SIMD select" operation** —
  popcount whole chunks and skip them while the running count stays below the
  target, then scalar-scan within the final chunk. That is the practical answer
  to "can SIMD do the inverse mapping", and it needs no exotic instruction.
- **Accumulation must be bounded**: byte lanes overflow after
  `(256/8) − 1 = 31` chunks, so defer the horizontal reduction.
- **ARM has no PDEP.** The `_tzcnt_u64(_pdep_u64(1ULL << i, word))` select
  trick (Pandey, Bender & Johnson,
  [arXiv:1706.00990](https://arxiv.org/pdf/1706.00990)) is x86-BMI2-only;
  SVE2's `BDEP` is absent on all Apple Silicon through M3. On this project's
  primary target, use the popcount-skip approach above, not PDEP.

Corrections to attributions I would otherwise have made from memory: there is
**no Lemire post benchmarking UTF-8 code-point counting** (the nearest is
Latin-1→UTF-8 sizing, AVX2, 0.055 cycles/byte vs 0.56 scalar — a *different*
operation, so treat it as an upper bound only), and the PDEP select trick is
Pandey et al., not Lemire. Solid published figures that *are* verified: UTF-8
validation ([arXiv:2010.03090](https://arxiv.org/abs/2010.03090)) at 0.21
instr/byte ASCII / 0.97 non-ASCII, 66 GiB/s ASCII and 13 GiB/s mixed on 16 kB
inputs. Note transcoding papers report **gigachars/s, not GB/s** — don't
conflate the units. My own 17.9 GB/s measurement above is the number that
actually matters here, since it is this operation on this machine.

---

### 5. Succinct rank/select bitvector

**What it is.** The textbook O(1) answer. Build a bitvector with a 1 at each
lead-byte position; then `byte_offset(i) = select1(i)`. `select` in O(1)
requires a two-level (or three-level) directory of superblock and block
cumulative counts, plus a lookup table for the final in-block resolution.

**Complexity.** Random O(1), sequential O(1).

**Memory.** This is where it dies. Verified constants: sdsl-lite
`rank_support_v` = **25%** of the bitvector, `rank_support_v5` = **6.25%**;
`select_support_mcl`'s header states a pessimistic **0.375n**, with Kurpicz
measuring **18.5%** in practice. rank9 = 25%. So the bitvector (12.5% of the
*byte* length) plus rank plus select lands around **~18% total at 100 KB**,
versus **~5% for a breadcrumb table** — roughly 3× the memory.

**And it is also *slower* at these sizes.** The decisive source is Pibiri &
Kanda ([arXiv:2009.12809](https://arxiv.org/pdf/2009.12809)), whose Figs. 12–13
sweep 2^9 to 2^32 bits — covering the entire JS-string range. Findings:

- Everything is **flat below ~2^22 bits**; the curves only separate once the
  data exceeds cache. Vigna corroborates: rank9 is **8.1–8.3 ns from 1 Ki to
  256 Ki bits**.
- Their plain block+popcount design runs **~2 ns/rank and ~9–11 ns/select**,
  versus Rank9 ~7 ns/rank and MCL/Hinted select ~13–27 ns. **The simple design
  is 2–5× faster than the succinct structures at small sizes**, not slower.
- Vigna documents that `select9` *"will generate four cache misses"* worst
  case. Zhou et al.'s cost hierarchy — ~100 ns per cache miss, ~5 ns per
  branch, <¼ ns per arithmetic op — explains why: at L1/L2-resident sizes the
  asymptotic advantage never activates, and the extra dependent cache lines
  dominate.
- Construction cost seals it: Kurpicz notes you can answer **2,000,000 select
  queries** in the time some of these structures take to build.

Critically, **breadcrumbs are a strictly better engineering point**: the
"superblock + block counts + scan the last block" structure *is* essentially a
degenerate rank/select directory, and stopping at two levels with a small scan
gets you within a small constant of O(1) for a fraction of the code.

**Verdict: theoretically interesting, empirically dominated by design 2 on
both memory (3×) and speed.** Succinct structures earn their complexity when
the data is huge and the overhead budget is a few percent of gigabytes. An 8 KB
JS string is emphatically not that regime. This candidate is now rejected on
fetched measurements, not just intuition.

---

### 6. Ropes

**What it is.** Ground truth from `quickjs/quickjs.c:593`:

```c
typedef struct JSStringRope {
    uint32_t len;
    uint8_t is_wide_char;
    uint8_t depth;        /* max depth of the rope tree */
    JSValue left;
    JSValue right;        /* might be the empty string */
} JSStringRope;
```
with `JS_STRING_ROPE_SHORT_LEN 512`, `JS_STRING_ROPE_SHORT2_LEN 8192`,
`JS_STRING_ROPE_MAX_DEPTH 60`, and Boehm/Atkinson/Plass rebalancing
(`js_rebalancee_string_rope`).

**How QuickJS keeps ropes from breaking identity — the important part.**
A rope is a **distinct JSValue tag** (`JS_TAG_STRING_ROPE`), *not* a JSString.
`JS_ToStringInternal` (line 13589) calls `js_linearize_string_rope` on any rope
before it can be used as a property key, and `js_linearize_string_rope`
(line 4822) flattens to a real `JSString` and then **mutates the rope in place
to memoize the result** (sets `r->left = flattened; r->right = empty_string`)
so it is never linearized twice. Atoms are therefore *never* ropes.

That is the pattern that makes ropes compatible with an interned world:
**ropes are a separate type that must be linearized before entering the
identity domain.** It is not "ropes are safe"; it is "ropes are quarantined
from the identity domain by construction."

**Complexity.** Rope indexing is O(depth) to find the leaf and then O(n)
*within* the leaf if the leaf is CESU-8. **Ropes do not solve the indexing
problem at all.** They solve a *different* problem: O(1) concatenation, which
is why QuickJS has them.

**Relevance here.** This codebase's string-building already has a mitigation
(the `MAX_INTERN_BYTES` non-interning path, added per the comment at
`heap.c3:3240` to fix O(n²) growth in concat loops). Ropes would be a
concatenation optimisation, and should be evaluated on that basis in a separate
investigation — they are **not a candidate for this problem**.

---

### 7. Chunked fixed-width segments

**What it is.** Split a string into fixed-size chunks, each independently
narrow or wide. Index = find chunk (O(1) if chunks hold a fixed number of
*units*), then index within it.

**Assessment.** This is design 3's memory profile improved (a mostly-ASCII
string with one CJK character only pays 2 bytes/unit for the one chunk
containing it) at the cost of design 3's simplicity. But it inherits *all* of
design 3's migration cost — the buffer is no longer contiguous, so `get_cstr()`
dies, the regexp path needs gathering, and `hash_string` needs care. It gives
up the "one contiguous allocation, NUL-terminated, hand it to C" property that
this codebase leans on heavily.

**Verdict: worst of both worlds for this codebase.** Only worth revisiting if
design 3 is chosen and its memory profile proves unacceptable.

---

## 4. Ranked recommendation

### Tier 1 — do these now (low risk, most of the win)

**1. Cache `charlen` in the HString header.** Fixes ~half the measured
`charCodeAt`/`charAt` cost and 100% of `.length` cost, for ~20 lines. Check
first whether `registry_slot` can shrink from `usz` to `uint`, which would make
it **free** in header bytes. Also remove the redundant `char_length()` calls:
`char_at` calls it for bounds checking while its caller
(`builtin_string_proto_charCodeAt`) has *already* computed it — pass the length
in or add an unchecked variant. This alone should take charCodeAt from ~17 ms
toward ~9 ms with no representational risk whatsoever.

**2. Duktape-style cursor cache.** 4 global entries, ~80 lines, makes all
*sequential* scanning O(1) amortised (measured 0.0095 ms vs 27 ms) and gives a
free 5× on random via scan-from-nearest-end. Sequential is the dominant real
pattern (`for (i=0;i<s.length;i++)`), and this handles it completely. Builds
the weak-reference machinery that design 3 (breadcrumbs) also needs.

### Tier 2 — the actual answer for random access

**3. Per-string breadcrumbs at stride 64, lazily built, in a heap-side weak
map, for non-ASCII strings above ~128 code units.** Measured **170× on random
access for 3.1% memory**, with a flat random/sequential profile. Crucially,
**interning-safe by construction** — it is side data keyed by an HString
pointer, and the large non-ASCII strings it targets are already non-interned
(`MAX_INTERN_BYTES = 256`), so pointer-identity equality is not even in play.
Build cost (~28 µs/8k string, one walk) amortises after two accesses.

Tiers 1–3 together are, in my judgement, **~95% of the achievable win for
maybe 250 lines and near-zero regression risk**, and they leave the CESU-8
representation, the interning invariant, `get_cstr()`, and the hash all
completely untouched.

### Tier 3 — only if the regexp path is the real target

**4. Migrate to fixed-width Latin-1/UTF-16 (design 3).** This is the only
option that makes access *truly* O(1) and the only one that **deletes the
regexp transcode** (currently 6 bytes of malloc + a full transcode + a
reverse-mapping pass per non-ASCII exec — the reason `indexOf` is 26 ms). It is
also what every major engine does, so it is where this ends up eventually.

But it is a large, risky migration: 160 direct call sites plus every byte-level
consumer, and it breaks `get_cstr()` NUL-termination, byte-wise
`hstring_compare`, and byte-wise `hash_string` — the last of which is an
interning-correctness hazard, not just a refactor.

**Do not start here.** Do Tier 1–2 first, re-measure, and only then decide
whether the remaining regexp gap justifies it. If it does, note that the
`cesu8_to_utf16` conversion could be attacked *directly and independently* by
caching the converted UTF-16 buffer on the string (the same weak-map machinery
again) — capturing much of the regexp win without the migration.

### Explicitly considered and rejected

- **"Do nothing / cursor cache is enough"** — *not* supported by the evidence.
  The cursor cache leaves random access at 5.34 ms vs 0.16 ms for breadcrumbs,
  a 33× gap, and random access is exactly what `s[i]` in a non-linear loop
  does. But "cursor cache *plus charlen caching* is enough" is a defensible
  stopping point if random-access workloads turn out to be rare in practice —
  see §5.
- **Succinct rank/select (5)** — dominated by breadcrumbs on every axis that
  matters at 8 KB scale.
- **Ropes (6)** — solves concatenation, not indexing. Wrong problem.
- **Chunked segments (7)** — design 3's cost without design 3's simplicity.
- **SIMD (4)** — good and zero-memory, but dominated by breadcrumbs on speed;
  worth adopting *specifically* to make breadcrumb builds ~30× cheaper, not as
  the primary mechanism.

---

## 5. What I could not determine and would need to prototype or measure

1. **Whether `registry_slot` can shrink to `uint`.** This decides whether
   caching `charlen` is free or costs 8 bytes/string. Needs a read of the
   large-string registry to check the slot-index range. High leverage,
   cheap to answer.

2. **The real random-vs-sequential mix in actual workloads.** My entire Tier 2
   argument rests on random access mattering. If profiling of the benchmark
   suite and test262 shows indexed string access is ~always sequential, Tier 1+2
   suffices and breadcrumbs can be dropped. **This is the single most
   decision-relevant unknown** and should be measured before building
   breadcrumbs — instrument `char_offset_to_byte_offset` to histogram
   `|requested_index - previous_index|`.

3. **Distribution of string lengths and non-ASCII fraction in real heaps.**
   Determines the breadcrumb threshold and whether header growth is affordable.
   The 8k-string benchmark may be unrepresentative; if p99 non-ASCII string
   length is 40 units, this whole problem is nearly moot and Tier 1 is the
   entire answer.

4. ~~Swift's actual breadcrumb stride and per-entry payload.~~ **Resolved.**
   Verified against `StringBreadcrumbs.swift`: stride is 64, payload is a
   packed `UInt32`. Swift's independent choice matches my measured sweep.

5. **What the regexp path costs after Tier 1+2.** `indexOf` at 26.1 ms mixes
   the index walk with the transcode. Once the walk is fixed, the residual is
   the true transcode cost and determines whether Tier 3 is justified. Measure
   by instrumenting `re_exec` directly.

6. **Whether `char_at`'s bounds check can be removed rather than cached.**
   Several callers (`vm_property.c3:271,446,674`) have already range-checked
   via `array_index() < char_length()` at `hobject.c3:2653`. An unchecked
   `char_at_unchecked` may be free correctness-wise; needs a call-site audit.

7. **Cross-architecture SIMD throughput.** My 17.9 GB/s is aarch64/NEON on one
   machine. The x86 SSE2/AVX2 figure is unmeasured, and the portability cost
   against the small-footprint goal is a judgement call I can't make from here.

---

## Sources

Read directly from the vendored trees in this repo (ground truth, not
secondary description):

- `quickjs/quickjs.c:575` — `struct JSString`, `is_wide_char`, `str8`/`str16` union
- `quickjs/quickjs.c:593` — `struct JSStringRope`
- `quickjs/quickjs.c:214-218` — rope length/depth thresholds
- `quickjs/quickjs.c:4822` — `js_linearize_string_rope`, memoization of flattening
- `quickjs/quickjs.c:13589` — `JS_ToStringInternal` linearizing before property-key use
- `duktape/duktape/src-separate/duk_heap.h:158-159` — `DUK_HEAP_STRCACHE_SIZE 4`, `DUK_HEAP_STRINGCACHE_NOCACHE_LIMIT 16`
- `duktape/duktape/src-separate/duk_heap.h:303` — `struct duk_strcache_entry`
- `duktape/duktape/src-separate/duk_heap_stringcache.c` — `duk_heap_strcache_offset_char2byte`, `duk__scan_forwards`/`duk__scan_backwards`, weak-reference removal
- `duktape/duktape/src-separate/duk_hstring.h:44,114-135,222-227` — `DUK_HSTRING_FLAG_ASCII` (lazily set), `clen`/`clen16` charlen caching
- `libregexp/re_wrapper.c:182-211,247,280` — `cesu8_to_utf16`, offset back-mapping, ASCII fast path
- `src/hstring.c3`, `src/heap.c3:3209-3260`, `src/builtins/string.c3`, `src/vm/vm_property.c3`, `src/hobject.c3` — this codebase

Measurements taken in this session (reproducible; sources in the session
scratchpad):
- `scratchpad/scan.c` — scalar walk vs NEON lead-byte counting, 17.9 GB/s
- `scratchpad/bench2.c` — breadcrumb stride sweep, cursor cache, fixed-width baseline
- `/tmp/t.js`, `/tmp/t2.js`, `/tmp/t3.js`, `/tmp/t4.js` — in-engine timings

Fetched and verified during this session (via a delegated survey of engine
internals):

- WTF `StringImpl.h` / `JSString.h` — `at()`, `is8Bit()`, the
  `isRopeInPointer`/`isSubstringInPointer`/`is8BitInPointer` alignment-bit
  triple, `s_refCountFlagIsStaticString`, `s_hashFlagStringKindIsAtom`
  (`1u << 4`) / `s_hashFlagStringKindIsSymbol` (`1u << 5`) with mask `0x30`,
  `s_hashFlag8BitBuffer` (`1u << 2`), `equalInline` (no identity fast path),
  `maxTraversalDepth = 8`, `maxLengthForOnStackResolve = 2048`
- V8 string hierarchy — `SeqOneByteString`/`SeqTwoByteString`/`ConsString`/
  `SlicedString`/`ThinString`, `kInternalizedTag == 0`, `ConsString::Get`
  as a correctness fallback rather than the intended path, `MakeThin`

Also fetched and verified: Swift `StringBreadcrumbs.swift` / `StringGuts.swift`
/ `StringUTF16View.swift` (stride 64, `_PackedCrumb`, atomic install, ASCII
bypass, one-crumb trick); sdsl-lite `rank_support_v`/`_v5`/`select_support_mcl`
headers; Pibiri & Kanda [arXiv:2009.12809](https://arxiv.org/pdf/2009.12809);
Vigna rank9/select9; Pandey/Bender/Johnson
[arXiv:1706.00990](https://arxiv.org/pdf/1706.00990); simdutf
`utf16_length_from_utf8`; Rust `str_indices` (`si_chars.rs`, `si_utf16.rs`,
`si_chunk.rs`); ropey `TextInfo`; PEP 393/623; JerryScript, XS/Moddable,
Hermes, SpiderMonkey, Boa, Espruino string sources.

Claims still made from memory and **not** verified against a fetched source,
flagged inline above: the
specific field layouts of SpiderMonkey and CPython PEP 393 (the *qualitative*
claim that both use per-string narrow/wide selection is well-established, but
field names were not verified here). Header byte-counts quoted for V8 and JSC
are arithmetic over fetched field lists rather than values read from a
constant — modern V8 uses `sizeof()` on `V8_OBJECT` types and no longer
exposes `kHeaderSize`.
