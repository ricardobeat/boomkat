# 114: Latin-1/UTF-16 strings and the string C API

Replace the CESU-8 string storage with two fixed widths: one byte per code unit
when every unit is at most 0xFF, two bytes (UTF-16) otherwise. Extend the C API
so hosts can create and read strings in UTF-8, Latin-1 or UTF-16, and borrow the
stored characters without copying. UTF-8 stays the default C interface.

Baseline: `main` at `59c4146d`.

## Current representation

`HString` (`src/hstring.c3:135`) stores CESU-8 inline after the header. Each
UTF-16 code unit is encoded on its own, so lone surrogates survive and astral
characters take six bytes. `is_ascii` (`src/hstring.c3:105`) marks strings whose
bytes are all below 0x80; for them `blen` is the length and indexing is direct.

Non-ASCII strings are variable width. `char_offset_to_byte_offset`
(`src/hstring.c3:326`) scans from the start, the end, or one cached
`(cached_char_offset, cached_byte_offset)` cursor. Sequential access is cheap.
Random access is O(n), so loops that index scattered positions in non-ASCII text
are O(n²).

RegExp runs QuickJS libregexp. ASCII input matches in 8-bit mode without a copy
(`src/re_wrapper.c`, `re_run_interruptible`). Any other input is transcoded to
UTF-16 with a per-unit byte-offset table on every exec, and captures are mapped
back through `unit_offset_to_byte_offset`.

The C API (`include/boomkat.h:128-143`) is UTF-8 only: `bk_new_string`,
`bk_read_string`, `bk_cstr` and `bk_to_cstring`. Output converts through
`write_cesu8_as_utf8` (`src/hstring.c3:980`).

`blen` appears in 54 files under `src/`, and `HString.get_data()` is called from
43. Both treat a string as a byte buffer.

## Target representation

| Width | Holds | Bytes per unit | Indexing |
|---|---|---|---|
| Narrow | every unit ≤ 0xFF | 1 (Latin-1) | `data[i]` |
| Wide | at least one unit > 0xFF | 2 (UTF-16, native endian) | `((ushort*)data)[i]` |

Rules:

- **Canonical width.** A string is narrow whenever it can be. Creation, slicing
  and concatenation narrow when the result has no unit above 0xFF. Interning and
  equality can then compare width first and bytes second.
- **Hash by code unit.** The hash is defined over the unit sequence, not the
  stored bytes, so a hash computed while building a wide buffer matches the
  narrow string it may become. With canonical width this only matters for
  builders that hash before they know the final width.
- **Length in units.** `length` is the unit count for both widths.
  `cached_charlen`, `cached_char_offset` and `cached_byte_offset` go away. The
  header shrinks by at least eight bytes.
- **`is_ascii` stays** as a sub-flag of narrow. ASCII strings remain valid UTF-8,
  so they are the zero-copy path to UTF-8 hosts and the one-byte fast path for
  JSON, number parsing and property keys.
- **NUL terminator.** Narrow strings keep a trailing NUL for internal C helpers.
  Wide strings carry a two-byte terminator.

Memory compared with CESU-8:

| Text | CESU-8 | New |
|---|---|---|
| ASCII | 1 | 1 |
| Latin-1 letters (é, ñ, ü, °) | 2 | 1 |
| BMP beyond Latin-1 (CJK, Cyrillic, €, curly quotes) | 2–3 | 2 |
| Astral (emoji) | 6 | 4 |
| n ASCII units plus one wide unit | n + 3 | 2n + 2 |

The last row is the only regression. A long ASCII payload with one `€`, `…` or
emoji doubles. Ropes or the concat accumulator should keep wide pieces separate
until a flatten is required; measure before adding anything for it.

## Hazards found in the current code

- **Symbols are detected by a 0xFF lead byte.** `finish_data` sets `is_symbol`
  when `data[0] == 0xFF` and `is_hidden` when the first two bytes are 0xFF
  (`src/hstring.c3:518-519`), and hidden slot names such as `"\xFFpromise"` are
  spelled that way (`src/heap.c3:1398`). 0xFF never occurs in CESU-8, but in
  Latin-1 it is `ÿ`. A JS string beginning with `ÿ` would be taken for a symbol.
  Symbol-ness must come from the flag set at symbol creation, never from the
  bytes. This change lands first, before the width switch.
- **Byte search assumes one encoding.** `find_bytes` and `rfind_bytes`
  (`src/hstring.c3:851-869`) are only correct when both operands share a width.
  Mixed-width search widens the needle or compares unit by unit.
- **Bytecode images** serialize strings through `Writer.string_ref` and
  `Reader.string_ref` (`src/bytecode_image.c3:68`, `:249`). The image format
  gains a width bit per string and a format version bump. Narrow constants can
  still be referenced from flash in `BYTECODE_ONLY` builds.
- **The lexer and compiler** take UTF-8 source. Identifier and literal interning
  decode to units and choose the width at creation. Source positions remain byte
  offsets into the source text, which is separate from string storage.
- **`has_extdata`** strings (`src/hstring.c3:112`) point at external buffers and
  need the same width tag.

## Engine migration

Each phase lands on `main` with `just test-local`, `just rosetta`,
`just modules`, a full test262 run and `just build-nonanbox` green.

### Phase 0: measure

Add `bench/mini/strings-intl.js` with:

- random `charCodeAt` and `s[i]` over CJK, Cyrillic and accented Latin text;
- `slice`, `indexOf` and `split` with offsets fed back in;
- regexp exec and replace over the same text;
- `JSON.parse` and `JSON.stringify` of payloads containing accents and emoji.

Record CESU-8 numbers and RSS. If they show no O(n) indexing or transcoding
cost on realistic sizes, stop after Phase 2 and keep the accessor layer.

### Phase 1: symbols off the byte prefix

Store symbol and hidden-symbol identity in flags only. Hidden slot names keep a
prefix for readability in dumps, but no code path tests the bytes. Acceptance:
grep for `0xFF` tests on string data finds none outside the creation helpers.

### Phase 2: unit accessor layer

Introduce width-neutral operations on `HString` and route every `blen` and
`get_data()` user through them while storage stays CESU-8:

- `unit_len()`, `unit_at(i)`;
- `units_equal`, `units_compare`, `find_units` and `rfind_units`;
- `slice_units(from, to)` returning a new string;
- a unit iterator with `next()` for forward scans;
- a `StringBuilder` that tracks the widest unit seen and chooses width at
  `finish`.

Keep one-byte fast paths behind `is_ascii()` where they exist today. Builtins
such as `String.prototype` methods, JSON, number parsing, `Intl` and Temporal
string parsing move to these APIs. Uses that need bytes for the host (error
messages, `console`, the CLI) go through one encoder, `write_utf8`.

Acceptance: outside `src/hstring.c3` and the encoders, no code reads `blen` or
indexes `get_data()` directly. Performance within noise of Phase 0 on the full
mini suite and Octane.

### Phase 3: switch storage

- Allocation takes a width. `finish_data` computes `is_ascii` and the hash over
  units.
- Concatenation of two narrow strings stays narrow. Any wide operand widens the
  result. `try_append_in_place` widens the accumulator in place when it has
  capacity, otherwise reallocates.
- Interning normalizes to canonical width before lookup.
- The cursor cache, `compute_charlen`, `normalize_to_cesu8` and the CESU-8
  scanning helpers are deleted.
- RegExp passes narrow strings with `cbuf_type` 0 and wide strings with
  `cbuf_type` 1 (2 when the `u` or `v` flag is set). The transcode and the
  offset table in `re_wrapper.c` are deleted; capture offsets are unit offsets.
- Bytecode image format version bump with a width bit per string.

Acceptance: Phase 0 benchmark shows O(1) indexing on non-ASCII text and no
regexp transcode. Octane and the mini suite are within noise or better. Heap
use on `test262` and Octane is equal or lower.

### Phase 4: build options

Keep a single representation in every target, including `boomkat_tiny`, unless
measurements show a real ESP32 workload losing. Two representations would
double the test matrix. The tiny build should report flash size before and after
Phase 3; the second width path in builtins is the expected cost.

## C API

UTF-8 stays the default and the only interface a plain C or microcontroller
embedder needs. Additions are explicit per encoding. Nothing existing changes
signature.

### Creation

```c
BK_API bk_value bk_new_string(bk_ctx ctx, const char *utf8, size_t length);        /* existing */
BK_API bk_value bk_new_string_latin1(bk_ctx ctx, const uint8_t *chars, size_t length);
BK_API bk_value bk_new_string_utf16(bk_ctx ctx, const uint16_t *units, size_t length);
```

`bk_new_string` rejects invalid UTF-8 with an exception rather than storing it.
`bk_new_string_utf16` accepts lone surrogates; the result narrows when every
unit fits.

### Reading

```c
typedef enum {
    BK_UTF8_REPLACE = 0,  /* lone surrogates become U+FFFD */
    BK_UTF8_STRICT  = 1   /* lone surrogates fail with BK_ERR_ENCODING (new, -9) */
} bk_utf8_mode;

BK_API bk_status bk_read_string(bk_ctx ctx, bk_value value, char *buffer,
                                size_t capacity, size_t *length);           /* existing, REPLACE */
BK_API bk_status bk_read_string_utf8(bk_ctx ctx, bk_value value, bk_utf8_mode mode,
                                     char *buffer, size_t capacity, size_t *length);
BK_API bk_status bk_read_string_utf16(bk_ctx ctx, bk_value value, uint16_t *buffer,
                                      size_t capacity, size_t *length);
BK_API size_t    bk_string_length(bk_ctx ctx, bk_value value);  /* UTF-16 units */
```

Readers return `BK_ERR_FULL` and report the required size in `*length` when
`capacity` is too small, so callers can size buffers in two calls. The current behavior of
`bk_read_string` with lone surrogates is unspecified; this plan fixes it as
REPLACE and documents it.

### Borrowed view

```c
typedef struct {
    const void *data;   /* uint8_t* (Latin-1) or uint16_t* (UTF-16) */
    size_t      length; /* code units */
    uint8_t     width;  /* 1 or 2 */
    uint8_t     ascii;  /* nonzero when width == 1 and every unit < 0x80 */
} bk_string_view;

BK_API bk_status bk_string_view_get(bk_ctx ctx, bk_value value, bk_string_view *out);
```

The view stays valid while the host holds `value` and makes no call that can run
JS or allocate on the engine heap. Strings do not move today; the contract still
says "until the next engine call" so a moving collector stays possible. An
`ascii` view is valid UTF-8 and can go straight to `printf`, sockets or files.
On a CESU-8 engine this function cannot exist, which is part of the case for
Phase 3.

### External strings

```c
typedef void (*bk_string_release)(void *opaque, const void *data, size_t length);

BK_API bk_value bk_new_external_string_latin1(bk_ctx ctx, const uint8_t *chars, size_t length,
                                              bk_string_release release, void *opaque);
BK_API bk_value bk_new_external_string_utf16(bk_ctx ctx, const uint16_t *units, size_t length,
                                             bk_string_release release, void *opaque);
```

These reuse `has_extdata`. The buffer must stay immutable until `release`.
External strings are never interned in place; interning copies. Uses are large
asset text on desktop hosts and constant tables in flash on ESP32.

### Who uses what

| Host | Create | Read |
|---|---|---|
| ESP32, Arduino, Linux CLI, servers | UTF-8 | UTF-8, or the view when `ascii` |
| Godot (UTF-8 at the GDExtension boundary) | UTF-8 | UTF-8 |
| Qt (`QString`), Windows (`wchar_t`), Unreal (`TCHAR`), Cocoa | UTF-16 | UTF-16 or view |
| Browser DOM (Ladybird) | UTF-16, external | view |

### C API phases

- Phase 2 adds `bk_new_string_latin1`, `bk_new_string_utf16`,
  `bk_read_string_utf8`, `bk_read_string_utf16` and `bk_string_length`, with
  conversions over CESU-8. Hosts can adopt them before the storage change.
- Phase 3 adds `bk_string_view_get` and the external-string constructors.
- `docs/embedding.md` documents the lone-surrogate policy and the view lifetime.
- Tests: a C test target that round-trips lone surrogates, astral characters,
  Latin-1 and the empty string through every creator and reader, and checks
  that views never outlive a GC triggered by an intervening call.

## Risks

- The 54-file migration is the bulk of the work. Phase 2 is mechanical but wide;
  a missed byte-level assumption surfaces as wrong results only on non-ASCII
  input, which most tests do not cover. Phase 0's benchmark fixtures double as
  regression inputs, and test262's `built-ins/String` and `built-ins/RegExp`
  directories cover surrogate edge cases.
- Width-specialized loops in builtins grow code size. Macros or generic
  functions in C3 keep one source per algorithm; check the tiny build's flash.
- The ASCII-plus-one-wide-unit doubling may show up in JSON-heavy embedders.
- UTF-8 hosts printing wide strings pay an encode they did not pay before. The
  view's `ascii` flag keeps the common case free.

## Open questions

- Should narrowing on slice be eager (scan the slice) or lazy (keep wide until
  the next intern or flatten)? Eager is simpler and keeps canonical width exact.
- Do any internal tables (property maps, atoms) benefit from a separate narrow
  intern table?
- Does `Intl`/ICU want UTF-16 input directly? If so the full-icu build gains
  from wide strings without transcoding.
