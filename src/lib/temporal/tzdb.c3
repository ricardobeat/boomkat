// IANA tz database lookup. The data lives in tzdata_generated.c3, written by
// scripts/tzdata/build_tzdata.py; its header comment describes the encoding.
//
// Everything is read in place from read-only tables. A lookup decodes one
// zone's table into a small thread-local cache (explicit transitions only,
// at most 255) and evaluates the zone's POSIX footer rule arithmetically for
// instants after the last explicit transition, so DST continues indefinitely.
//
// Public API:
//   - tzdb_offset_for_zone_at(zone_name, epoch_sec) -> offset_sec
//   - tzdb_zone_exists(zone_name) -> bool
//   - tzdb_zone_index(zone_name) -> index in name order, or -1 if absent
//   - tzdb_next_transition / tzdb_prev_transition -> offset changes
module boomkat::lib::temporal;

import std::math;

struct TzdbCache {
    bool valid;
    uint table;
    int initial;
    uint count;
    long[256] at;
    int[256] off;
    bool has_footer;
    int std_off;
    int dst_off;
    uint start_rule;
    uint end_rule;
}

tlocal TzdbCache g_tzdb_cache;

// =============================================================================
// Rules
// =============================================================================

// Weekday of a civil date, 0 = Sunday.
fn long tzdb_weekday(long y, int m, long d) @private {
    long w = (epoch_days_from_civil(y, m, (int)d) + 4) % 7;
    return w < 0 ? w + 7 : w;
}

// The UTC instant a packed rule fires in `year`. Rule times are wall times on
// the offset in effect before the transition.
fn long tzdb_rule_epoch(long year, uint rule, int offset_before) @private {
    int month = (int)(rule & 15);
    uint dayspec = (rule >> 4) & 0xFF;
    long secs = (long)((int)rule >> 12);
    long day;
    if (dayspec < 0x80) {
        day = (long)dayspec;
    } else {
        long weekday = (long)((dayspec >> 3) & 7);
        long week = (long)(dayspec & 7);
        if (week == 5) {
            day = (long)days_in_month(year, month);
            while (tzdb_weekday(year, month, day) != weekday) day--;
        } else {
            day = 7 * (week - 1) + 1;
            while (tzdb_weekday(year, month, day) != weekday) day++;
        }
    }
    return epoch_days_from_civil(year, month, (int)day) * 86400 + secs - offset_before;
}

// The footer's two transitions in `year`, in time order.
fn void tzdb_footer_year(TzdbCache* c, long year, long* t0, int* o0, long* t1, int* o1) @private {
    long start = tzdb_rule_epoch(year, c.start_rule, c.std_off);
    long end = tzdb_rule_epoch(year, c.end_rule, c.dst_off);
    if (start <= end) {
        *t0 = start; *o0 = c.dst_off; *t1 = end; *o1 = c.std_off;
    } else {
        *t0 = end; *o0 = c.std_off; *t1 = start; *o1 = c.dst_off;
    }
}

// Latest footer transition at or before `t` and after `floor` (the last
// explicit transition: the footer applies only past it).
fn bool tzdb_footer_prev(TzdbCache* c, long t, long floor, long* at, int* off) @private {
    if (!c.has_footer) return false;
    long year = civil_from_seconds(t + c.std_off).y + 1;
    for (int k = 0; k < 4; k++) {
        long t0; long t1; int o0; int o1;
        tzdb_footer_year(c, year, &t0, &o0, &t1, &o1);
        if (t1 <= t) {
            if (t1 <= floor) return false;
            *at = t1; *off = o1; return true;
        }
        if (t0 <= t) {
            if (t0 <= floor) return false;
            *at = t0; *off = o0; return true;
        }
        year--;
    }
    return false;
}

// Earliest footer transition after both `t` and `floor`.
fn bool tzdb_footer_next(TzdbCache* c, long t, long floor, long* at, int* off) @private {
    if (!c.has_footer) return false;
    long lo = math::max(t, floor);
    long year = civil_from_seconds(lo + c.std_off).y - 1;
    for (int k = 0; k < 4; k++) {
        long t0; long t1; int o0; int o1;
        tzdb_footer_year(c, year, &t0, &o0, &t1, &o1);
        if (t0 > lo) { *at = t0; *off = o0; return true; }
        if (t1 > lo) { *at = t1; *off = o1; return true; }
        year++;
    }
    return false;
}

// =============================================================================
// Table decoding
// =============================================================================

fn uint tzdb_bits(usz base, usz* bitpos, uint width) @private {
    uint value = 0;
    for (uint b = 0; b < width; b++) {
        usz p = *bitpos;
        value |= (uint)((TZDB_TABLES[base + (p >> 3)] >> (p & 7)) & 1) << b;
        *bitpos = p + 1;
    }
    return value;
}

fn uint tzdb_width(uint count) @private {
    uint w = 0;
    if (count <= 1) return 0;
    while (((count - 1) >> w) != 0) w++;
    return w;
}

// Decode the table of zone `idx` into the thread-local cache.
fn TzdbCache* tzdb_load(int idx) @private {
    TzdbCache* c = &g_tzdb_cache;
    uint table = TZDB_ZONE_TABLE[idx];
    if (c.valid && c.table == table) return c;
    usz pos = TZDB_TABLE_AT[table];
    c.valid = true;
    c.table = table;
    c.initial = TZDB_OFFSETS[TZDB_TABLES[pos]];
    uint n = TZDB_TABLES[pos + 1];
    pos += 2;
    c.count = n;
    ushort[256] rule_pal;
    char[256] off_pal;
    uint year = 0;
    uint rules = 0;
    uint offs = 0;
    if (n > 0) {
        year = (uint)(int)(short)(TZDB_TABLES[pos] | (TZDB_TABLES[pos + 1] << 8));
        rules = TZDB_TABLES[pos + 2];
        pos += 3;
        for (uint i = 0; i < rules; i++) {
            rule_pal[i] = (ushort)(TZDB_TABLES[pos] | (TZDB_TABLES[pos + 1] << 8));
            pos += 2;
        }
        offs = TZDB_TABLES[pos];
        pos++;
        for (uint i = 0; i < offs; i++) off_pal[i] = TZDB_TABLES[pos + i];
        pos += offs;
    }
    c.has_footer = TZDB_TABLES[pos] == 1;
    if (c.has_footer) {
        c.std_off = TZDB_OFFSETS[TZDB_TABLES[pos + 1]];
        c.dst_off = TZDB_OFFSETS[TZDB_TABLES[pos + 2]];
        c.start_rule = TZDB_RULES[TZDB_TABLES[pos + 3] | (TZDB_TABLES[pos + 4] << 8)];
        c.end_rule = TZDB_RULES[TZDB_TABLES[pos + 5] | (TZDB_TABLES[pos + 6] << 8)];
        pos += 7;
    } else {
        pos++;
    }
    usz bitpos = 0;
    uint rw = tzdb_width(rules);
    uint ow = tzdb_width(offs);
    long y = (long)(int)year;
    int prev = c.initial;
    for (uint i = 0; i < n; i++) {
        uint r = tzdb_bits(pos, &bitpos, rw);
        uint o = tzdb_bits(pos, &bitpos, ow);
        uint step = tzdb_bits(pos, &bitpos, 2);
        if (step == 3) {
            uint z = tzdb_bits(pos, &bitpos, 16);
            y += (long)(z >> 1) ^ -(long)(z & 1);
        } else {
            y += (long)step;
        }
        c.at[i] = tzdb_rule_epoch(y, TZDB_RULES[rule_pal[r]], prev);
        prev = TZDB_OFFSETS[off_pal[o]];
        c.off[i] = prev;
    }
    return c;
}

// =============================================================================
// Lookup on a decoded table
// =============================================================================

// Index of the first explicit transition after `t`.
fn uint tzdb_upper(TzdbCache* c, long t) @private {
    uint lo = 0;
    uint hi = c.count;
    while (lo < hi) {
        uint mid = lo + (hi - lo) / 2;
        if (c.at[mid] <= t) { lo = mid + 1; } else { hi = mid; }
    }
    return lo;
}

fn long tzdb_floor(TzdbCache* c) @private {
    return c.count > 0 ? c.at[c.count - 1] : -1;
}

fn int tzdb_cache_offset_at(TzdbCache* c, long epoch) @private {
    long at; int off;
    if (tzdb_footer_prev(c, epoch, tzdb_floor(c), &at, &off)) return off;
    uint i = tzdb_upper(c, epoch);
    return i == 0 ? c.initial : c.off[i - 1];
}

// Earliest transition after `t` that changes the offset.
fn bool tzdb_cache_next(TzdbCache* c, long t, long* at, int* off) @private {
    for (int guard = 0; guard < 64; guard++) {
        uint i = tzdb_upper(c, t);
        long x; int o;
        if (i < c.count) {
            x = c.at[i]; o = c.off[i];
        } else if (!tzdb_footer_next(c, t, tzdb_floor(c), &x, &o)) {
            return false;
        }
        if (tzdb_cache_offset_at(c, x - 1) != o) { *at = x; *off = o; return true; }
        t = x;
    }
    return false;
}

// Latest transition at or before `t` that changes the offset.
fn bool tzdb_cache_prev(TzdbCache* c, long t, long* at, int* off) @private {
    for (int guard = 0; guard < 64; guard++) {
        long x; int o;
        if (!tzdb_footer_prev(c, t, tzdb_floor(c), &x, &o)) {
            uint i = tzdb_upper(c, t);
            if (i == 0) return false;
            x = c.at[i - 1]; o = c.off[i - 1];
        }
        if (tzdb_cache_offset_at(c, x - 1) != o) { *at = x; *off = o; return true; }
        t = x - 1;
    }
    return false;
}

// =============================================================================
// Zone names
// =============================================================================

// Decode the front-coded name at `*pos` over the previous name in `buf`.
fn usz tzdb_name_step(char* buf, usz* pos) @private {
    usz shared = TZDB_NAMES[*pos];
    usz rest = TZDB_NAMES[*pos + 1];
    for (usz i = 0; i < rest; i++) buf[shared + i] = TZDB_NAMES[*pos + 2 + i];
    *pos += 2 + rest;
    return shared + rest;
}

// Write the name of zone `idx` into `buf` (at least 64 bytes); returns its length.
fn usz tzdb_zone_name(int idx, char* buf) {
    usz block = (usz)idx / TZDB_NAME_BLOCK;
    usz pos = TZDB_NAME_AT[block];
    usz n = 0;
    for (usz k = 0; k <= (usz)idx % TZDB_NAME_BLOCK; k++) n = tzdb_name_step(buf, &pos);
    return n;
}

// Binary-search the blocks by first name, then scan the block.
fn int tzdb_zone_index(String zone_name) {
    if (zone_name.len == 0 || zone_name.len > 63) return -1;
    char[64] buf;
    char* p = &buf[0];
    usz lo = 0;
    usz hi = TZDB_NAME_AT.len;
    while (lo < hi) {
        usz mid = lo + (hi - lo) / 2;
        usz pos = TZDB_NAME_AT[mid];
        usz n = tzdb_name_step(p, &pos);
        if (string_compare((String)buf[:n], zone_name) <= 0) { lo = mid + 1; } else { hi = mid; }
    }
    if (lo == 0) return -1;
    usz block = lo - 1;
    usz pos = TZDB_NAME_AT[block];
    for (usz k = 0; k < TZDB_NAME_BLOCK; k++) {
        usz idx = block * TZDB_NAME_BLOCK + k;
        if (idx >= TZDB_ZONE_TABLE.len) break;
        usz n = tzdb_name_step(p, &pos);
        if (string_compare((String)buf[:n], zone_name) == 0) return (int)idx;
    }
    return -1;
}

// Index of the zone whose name matches `zone_name` ignoring ASCII case.
fn int tzdb_zone_index_ci(String zone_name) @private {
    int idx = tzdb_zone_index(zone_name);
    if (idx >= 0) return idx;
    if (zone_name.len == 0 || zone_name.len > 63) return -1;
    char[64] buf;
    char* p = &buf[0];
    usz pos = 0;
    for (usz i = 0; i < TZDB_ZONE_TABLE.len; i++) {
        if (i % TZDB_NAME_BLOCK == 0) pos = TZDB_NAME_AT[i / TZDB_NAME_BLOCK];
        usz n = tzdb_name_step(p, &pos);
        if (ci_zone_eq(zone_name, (String)buf[:n])) return (int)i;
    }
    return -1;
}

// String compare returning <0 / 0 / >0. Both inputs are non-null String values.
fn int string_compare(String a, String b) {
    usz n = a.len < b.len ? a.len : b.len;
    for (usz i = 0; i < n; i++) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

// ASCII case-insensitive zone-name comparison.
fn bool ci_zone_eq(String a, String b) {
    if (a.len != b.len) return false;
    for (usz k = 0; k < a.len; k++) {
        char ca = a[k];
        char cb = b[k];
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
        if (ca != cb) return false;
    }
    return true;
}

// =============================================================================
// Public API
// =============================================================================

// True if `zone_name` is a recognized IANA zone.
fn bool tzdb_zone_exists(String zone_name) {
    return tzdb_zone_index(zone_name) >= 0;
}

// Case-insensitive existence check, used where the spec lets "utC" or
// "America/NEW_YORK" match the canonical spelling. The canonical name is
// written (NUL-terminated, truncated to `buf_cap`) into `canonical_buf`.
fn bool tzdb_zone_exists_ci(String zone_name, char* canonical_buf, usz buf_cap) {
    int idx = tzdb_zone_index_ci(zone_name);
    if (idx < 0) return false;
    if (canonical_buf != null && buf_cap > 0) {
        char[64] name;
        usz n = tzdb_zone_name(idx, &name[0]);
        if (n > buf_cap - 1) n = buf_cap - 1;
        for (usz k = 0; k < n; k++) canonical_buf[k] = name[k];
        canonical_buf[n] = 0;
    }
    return true;
}

fn int tzdb_offset_at_index(int idx, long epoch_sec) @private {
    return tzdb_cache_offset_at(tzdb_load(idx), epoch_sec);
}

// Like tzdb_offset_for_zone_at, but the name matches ignoring case and the
// canonical spelling is copied into `canonical_buf` (not NUL-terminated).
// Returns -1 for an unknown zone.
fn int tzdb_offset_for_zone_ci(String zone_name, long epoch_sec, char* canonical_buf, usz buf_cap) {
    int idx = tzdb_zone_index_ci(zone_name);
    if (idx < 0) return -1;
    if (canonical_buf != null && buf_cap > 0) {
        char[64] name;
        usz n = tzdb_zone_name(idx, &name[0]);
        if (n > buf_cap) n = buf_cap;
        for (usz i = 0; i < n; i++) canonical_buf[i] = name[i];
    }
    return tzdb_offset_at_index(idx, epoch_sec);
}

// The zone's offset from UTC (seconds) at `epoch_sec`. Accepts "Z" and
// fixed offsets (+HH[:MM]). Returns 0 for an unrecognized zone; callers
// validate the name first. Before the first transition the zone's initial
// offset applies.
fn int tzdb_offset_for_zone_at(String zone_name, long epoch_sec) {
    if (zone_name.len > 0) {
        char first = zone_name.ptr[0];
        if (first == 'Z' || first == 'z') return 0;
        if (first == '+' || first == '-') {
            bool neg = (first == '-');
            int h = 0;
            int mi = 0;
            if (zone_name.len >= 3) {
                h = (zone_name.ptr[1] - '0') * 10 + (zone_name.ptr[2] - '0');
            }
            if (zone_name.len >= 5 && zone_name.ptr[3] == ':') {
                mi = (zone_name.ptr[4] - '0') * 10 + (zone_name.ptr[5] - '0');
            }
            int off = h * 3600 + mi * 60;
            return neg ? -off : off;
        }
    }
    int idx = tzdb_zone_index(zone_name);
    if (idx < 0) return 0;
    return tzdb_offset_at_index(idx, epoch_sec);
}

// The offset in effect before the zone's first transition; 0 if unknown.
fn int tzdb_zone_initial_offset(String zone_name) {
    int idx = tzdb_zone_index(zone_name);
    if (idx < 0) return 0;
    return tzdb_load(idx).initial;
}

// The first transition after `t_sec` that changes the zone's offset. Writes
// its instant to `at` and the new offset to `offset_after`. Zones with a
// daylight saving rule always have a next transition.
fn bool tzdb_next_transition(String zone_name, long t_sec, long* at, int* offset_after) {
    int idx = tzdb_zone_index(zone_name);
    if (idx < 0) return false;
    return tzdb_cache_next(tzdb_load(idx), t_sec, at, offset_after);
}

// The last transition at or before `t_sec` that changes the zone's offset.
fn bool tzdb_prev_transition(String zone_name, long t_sec, long* at) {
    int idx = tzdb_zone_index(zone_name);
    if (idx < 0) return false;
    int off;
    return tzdb_cache_prev(tzdb_load(idx), t_sec, at, &off);
}

// ---- Local wall time -> epoch nanoseconds, via the zone's transitions ----

// Append an offset value to the deduplicated candidate list (in place).
fn void tz_cand_add(int[] cand, int* nc, int o) {
    int n = *nc;
    for (int k = 0; k < n; k++) {
        if (cand[k] == o) return;
    }
    if (n < 8) { cand[n] = o; *nc = n + 1; }
}

// Resolve a wall-clock time in `zone` to the UTC offset to subtract from it
// (ES Temporal GetPossibleEpochNanoseconds + DisambiguatePossibleEpochNanoseconds).
// `mode`: 0 compatible, 1 earlier, 2 later, 3 reject. Set `*rejected` when mode
// is reject and the wall time is skipped or repeated.
//
// Candidate offsets are those in force within two days of the wall time; a
// candidate is valid when the zone has that offset at the instant it yields.
// A repeated wall time (fall back) has two valid offsets; the larger gives
// the earlier instant. A skipped wall time (spring forward) has none: "later"
// and "compatible" use the offset before the gap, which lands after it, and
// "earlier" the offset after the gap.
fn long tzdb_resolve_local(String zone, long wall_secs, int mode, bool* rejected) {
    int[8] cand;
    int nc = 0;
    tz_cand_add(cand[..], &nc, tzdb_offset_for_zone_at(zone, wall_secs));
    long window = 2 * 86400;
    long t = wall_secs - window - 1;
    long at; int after;
    while (tzdb_next_transition(zone, t, &at, &after) && at <= wall_secs + window) {
        tz_cand_add(cand[..], &nc, tzdb_offset_for_zone_at(zone, at - 1));
        tz_cand_add(cand[..], &nc, after);
        t = at;
    }
    if (nc == 0) tz_cand_add(cand[..], &nc, 0);
    int lo = cand[0];
    int hi = cand[0];
    int vlo = 0;
    int vhi = 0;
    int valid = 0;
    for (int k = 0; k < nc; k++) {
        lo = math::min(lo, cand[k]);
        hi = math::max(hi, cand[k]);
        if (tzdb_offset_for_zone_at(zone, wall_secs - cand[k]) != cand[k]) continue;
        if (valid == 0) { vlo = cand[k]; vhi = cand[k]; }
        vlo = math::min(vlo, cand[k]);
        vhi = math::max(vhi, cand[k]);
        valid++;
    }
    if (valid == 1) return vhi;
    if (mode == 3) { *rejected = true; return lo; }
    if (valid > 1) return mode == 2 ? vlo : vhi;
    return mode == 1 ? hi : lo;
}

// Resolve a wall-clock time in `zone` to an epoch-nanosecond instant with the
// "compatible" disambiguation. Offsets are whole seconds, so the result is an
// int128 to keep nanosecond precision.
fn int128 zdt_local_to_epoch_ns(String zone, long wall_secs, long wall_frac_ns) {
    if (zone.len == 0 || zone.ptr == null) {
        return (int128)wall_secs * 1000000000 + (int128)wall_frac_ns;
    }
    bool rejected = false;
    long off = tzdb_resolve_local(zone, wall_secs, 0, &rejected);
    return (int128)(wall_secs - off) * 1000000000 + (int128)wall_frac_ns;
}
