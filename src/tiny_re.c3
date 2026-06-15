/// tiny_re — Minimal regexp engine in C3
///
/// Supports: . * + ? {n} {n,m} () | [...] \d \w \s \D \W \S ^ $
module duktape::tiny_re;

import libc;
import duktape::types;

const int RE_FLAG_IGNORECASE = 2;
const int RE_FLAG_MULTILINE  = 4;
const int RE_FLAG_DOTALL     = 8;
const int RE_MATCH    = 1;
const int RE_NO_MATCH = 0;
const int RE_ERROR    = -1;
const int RE_MAX_CAPTURES = 32;

enum ReOp : char {
    MATCH_CHAR,
    MATCH_CHAR_CI,
    MATCH_ANY,
    MATCH_ANY_ALL,
    MATCH_CLASS,
    MATCH_START,
    MATCH_END,
    SPLIT,
    JMP,
    SAVE,
    ACCEPT,
}

struct ReCompiled {
    char* code;
    int   code_len;
    int   num_captures;
    int   flags;
    char* classes;
}

struct ReCompiler {
    char*  pattern;
    int    pat_len;
    int    pos;
    int    flags;
    char*  code;
    int    code_len;
    int    code_cap;
    char*  classes;
    int    class_count;
    int    next_group;
}

fn void re_emit(ReCompiler* c, char b) {
    if (c.code_len >= c.code_cap) return;
    c.code[c.code_len] = b;
    c.code_len++;
}

fn void re_emit_op(ReCompiler* c, ReOp op) {
    re_emit(c, (char)op);
}

fn void re_emit2(ReCompiler* c, ReOp op, char a) {
    re_emit(c, (char)op);
    re_emit(c, a);
}

fn void re_emit3(ReCompiler* c, ReOp op, int val) {
    re_emit(c, (char)op);
    re_emit(c, (char)(val & 0xFF));
    re_emit(c, (char)((val >> 8) & 0xFF));
}

fn int re_read_off(char* code, int pc) @inline {
    int val = (int)(usz)code[pc + 1] | ((int)(usz)code[pc + 2] << 8);
    if (val > 32767) val -= 65536;
    return val;
}

fn void re_patch_off(ReCompiler* c, int pc, int val) @inline {
    c.code[pc + 1] = (char)(val & 0xFF);
    c.code[pc + 2] = (char)((val >> 8) & 0xFF);
}

fn void cls_set(char* bm, int ch) @inline {
    bm[ch >> 3] |= (char)(1 << (ch & 7));
}

fn bool cls_test(char* bm, int ch) @inline {
    return (bm[ch >> 3] & (1 << (ch & 7))) != 0;
}

fn void cls_negate(char* bm) {
    for (int i = 0; i < 32; i++) bm[i] = ~bm[i];
}

fn void cls_fill_range(char* bm, int lo, int hi) {
    for (int i = lo; i <= hi; i++) cls_set(bm, i);
}

fn void cls_fill_shorthand(char* bm, char code) {
    if (code == 'd') { cls_fill_range(bm, '0', '9'); }
    else if (code == 'D') { cls_fill_range(bm, '0', '9'); cls_negate(bm); }
    else if (code == 'w') { cls_fill_range(bm, '0', '9'); cls_fill_range(bm, 'a', 'z'); cls_fill_range(bm, 'A', 'Z'); cls_set(bm, '_'); }
    else if (code == 'W') { cls_fill_range(bm, '0', '9'); cls_fill_range(bm, 'a', 'z'); cls_fill_range(bm, 'A', 'Z'); cls_set(bm, '_'); cls_negate(bm); }
    else if (code == 's') { cls_set(bm, ' '); cls_set(bm, '\t'); cls_set(bm, '\n'); cls_set(bm, '\r'); cls_set(bm, '\f'); }
    else if (code == 'S') { cls_set(bm, ' '); cls_set(bm, '\t'); cls_set(bm, '\n'); cls_set(bm, '\r'); cls_set(bm, '\f'); cls_negate(bm); }
}

fn void cls_expand_ci(char* bm) {
    char[32] copy;
    libc::memcpy(&copy, bm, 32);
    for (int i = 'A'; i <= 'Z'; i++) {
        if (cls_test(&copy, i)) { cls_set(bm, i + 32); }
    }
    for (int i = 'a'; i <= 'z'; i++) {
        if (cls_test(&copy, i)) { cls_set(bm, i - 32); }
    }
}

fn int cls_alloc(ReCompiler* c) {
    int idx = c.class_count;
    c.class_count++;
    int off = idx * 32;
    if (off + 32 > 512) return -1;
    libc::memset(c.classes + off, 0, 32);
    return idx;
}

fn bool re_at_end(ReCompiler* c) @inline { return c.pos >= c.pat_len; }
fn char re_peek(ReCompiler* c) { return re_at_end(c) ? 0 : c.pattern[c.pos]; }
fn char re_adv(ReCompiler* c) { if (re_at_end(c)) return 0; char ch = c.pattern[c.pos]; c.pos++; return ch; }
fn bool re_eat(ReCompiler* c, char ch) { if (re_peek(c) != ch) return false; c.pos++; return true; }
fn bool re_is_digit(char ch) @inline { return ch >= '0' && ch <= '9'; }

fn int re_parse_int(ReCompiler* c) {
    int val = 0; bool ok = false;
    while (!re_at_end(c) && re_is_digit(re_peek(c))) {
        val = val * 10 + (int)(re_adv(c) - '0'); ok = true;
    }
    return ok ? val : -1;
}

fn char re_to_lower(char ch) @inline {
    return (ch >= 'A' && ch <= 'Z') ? ch + 32 : ch;
}

fn bool re_eq_ci(char a, char b) @inline {
    return re_to_lower(a) == re_to_lower(b);
}

fn int? re_parse_class(ReCompiler* c) {
    int ci = cls_alloc(c);
    if (ci < 0) return types::ALLOC_ERROR~;
    char* bm = c.classes + ci * 32;
    bool neg = re_eat(c, '^');
    bool first = true;
    while (!re_at_end(c) && (first || re_peek(c) != ']')) {
        first = false;
        char ch;
        if (re_eat(c, '\\')) {
            if (re_at_end(c)) break;
            char esc = re_adv(c);
            if (esc == 'd' || esc == 'D' || esc == 'w' || esc == 'W' || esc == 's' || esc == 'S') {
                cls_fill_shorthand(bm, esc);
                continue;
            }
            ch = (esc == 'n') ? '\n' : (esc == 'r') ? '\r' : (esc == 't') ? '\t' : esc;
        } else {
            ch = re_adv(c);
        }
        if (re_peek(c) == '-' && c.pos + 1 < c.pat_len && c.pattern[c.pos + 1] != ']') {
            c.pos++;
            char end_ch = re_eat(c, '\\') ? re_adv(c) : re_adv(c);
            cls_fill_range(bm, (int)(usz)ch, (int)(usz)end_ch);
        } else {
            cls_set(bm, (int)(usz)ch);
        }
    }
    re_eat(c, ']');
    if (c.flags & RE_FLAG_IGNORECASE) cls_expand_ci(bm);
    if (neg) cls_negate(bm);
    return ci;
}

fn int re_parse_esc(ReCompiler* c) {
    if (re_at_end(c)) return -(int)'\\';
    char esc = re_adv(c);
    if (esc == 'd' || esc == 'D' || esc == 'w' || esc == 'W' || esc == 's' || esc == 'S') {
        int ci = cls_alloc(c);
        if (ci < 0) return -(int)'x';
        cls_fill_shorthand(c.classes + ci * 32, esc);
        if (c.flags & RE_FLAG_IGNORECASE) cls_expand_ci(c.classes + ci * 32);
        return ci;
    }
    if (esc == 'n') return -(int)'\n';
    if (esc == 'r') return -(int)'\r';
    if (esc == 't') return -(int)'\t';
    if (esc == 'f') return -(int)'\f';
    if (esc == '0') return -(int)'\0';
    return -(int)(usz)esc;
}

fn int? re_parse_atom(ReCompiler* c) {
    if (re_at_end(c)) return 0;
    char ch = re_peek(c);

    if (ch == '^') { c.pos++; re_emit_op(c, ReOp.MATCH_START); return 1; }
    if (ch == '$') { c.pos++; re_emit_op(c, ReOp.MATCH_END); return 1; }

    if (ch == '(') {
        c.pos++;
        bool capturing = true;
        if (re_eat(c, '?')) {
            if (!re_eat(c, ':')) return types::SYNTAX_ERROR~;
            capturing = false;
        }
        int gidx = -1;
        if (capturing) {
            gidx = c.next_group;
            c.next_group++;
            if (gidx > RE_MAX_CAPTURES) return types::SYNTAX_ERROR~;
            re_emit3(c, ReOp.SAVE, gidx * 2);
        }
        int? r = re_parse_alt(c);
        if (catch e = r) return r;
        if (!re_eat(c, ')')) return types::SYNTAX_ERROR~;
        if (capturing) re_emit3(c, ReOp.SAVE, gidx * 2 + 1);
        return 1;
    }

    if (ch == '[') {
        c.pos++;
        int? ci = re_parse_class(c);
        if (catch e = ci) return ci;
        re_emit2(c, ReOp.MATCH_CLASS, (char)ci);
        return 1;
    }

    if (ch == '\\') {
        c.pos++;
        int r = re_parse_esc(c);
        if (r >= 0) {
            re_emit2(c, ReOp.MATCH_CLASS, (char)r);
        } else {
            char lit = (char)(-r);
            ReOp op = (c.flags & RE_FLAG_IGNORECASE) ? ReOp.MATCH_CHAR_CI : ReOp.MATCH_CHAR;
            re_emit2(c, op, lit);
        }
        return 1;
    }

    if (ch == '.') {
        c.pos++;
        re_emit_op(c, (c.flags & RE_FLAG_DOTALL) ? ReOp.MATCH_ANY_ALL : ReOp.MATCH_ANY);
        return 1;
    }

    if (ch == '*' || ch == '+' || ch == '?') return types::SYNTAX_ERROR~;

    c.pos++;
    ReOp op = (c.flags & RE_FLAG_IGNORECASE) ? ReOp.MATCH_CHAR_CI : ReOp.MATCH_CHAR;
    re_emit2(c, op, ch);
    return 1;
}

fn int? re_parse_quant(ReCompiler* c) {
    int as = c.code_len;
    int? ar = re_parse_atom(c);
    if (catch e = ar) return ar;
    if (ar == 0) return 0;

    if (re_at_end(c)) return 1;
    char q = re_peek(c);
    int mn = 1;
    int mx = 1;

    if (q == '*') { c.pos++; mn = 0; mx = -1; }
    else if (q == '+') { c.pos++; mn = 1; mx = -1; }
    else if (q == '?') { c.pos++; mn = 0; mx = 1; }
    else if (q == '{') {
        c.pos++;
        int n = re_parse_int(c);
        if (n < 0) return types::SYNTAX_ERROR~;
        mn = n;
        if (re_eat(c, ',')) { int m = re_parse_int(c); mx = (m < 0) ? -1 : m; }
        else { mx = n; }
        if (!re_eat(c, '}')) return types::SYNTAX_ERROR~;
    } else { return 1; }

    bool lazy = re_eat(c, '?');

    int alen = c.code_len - as;
    char[256] abc;
    if (alen > 256) return types::SYNTAX_ERROR~;
    libc::memcpy(&abc, c.code + as, (usz)alen);
    c.code_len = as;

    for (int i = 0; i < mn; i++) {
        libc::memcpy(c.code + c.code_len, &abc, (usz)alen);
        c.code_len += alen;
    }

    if (mx == -1) {
        // Unlimited repetition
        int sp = c.code_len;
        if (lazy) {
            // Lazy: try skip first (pc+3 = JMP exit), then atom (pc+offset)
            // Layout: SPLIT JMP_exit atom JMP_back
            re_emit3(c, ReOp.SPLIT, 0); // patch to atom offset
            re_emit3(c, ReOp.JMP, 0);   // patch to exit
            int atom_pc = c.code_len;
            libc::memcpy(c.code + c.code_len, &abc, (usz)alen);
            c.code_len += alen;
            re_emit3(c, ReOp.JMP, sp - c.code_len); // loop back to SPLIT
            // Patch SPLIT offset to point to atom
            re_patch_off(c, sp, atom_pc - sp);
            // Patch exit JMP to skip past the loop
            re_patch_off(c, sp + 3, c.code_len - (sp + 3));
        } else {
            // Greedy: try atom first (pc+3), then skip (pc+offset)
            // Layout: SPLIT atom JMP_back  [offset skips past JMP]
            re_emit3(c, ReOp.SPLIT, 0); // patch to skip offset
            libc::memcpy(c.code + c.code_len, &abc, (usz)alen);
            c.code_len += alen;
            re_emit3(c, ReOp.JMP, sp - c.code_len); // loop back to SPLIT
            // Patch SPLIT to skip past the JMP (second branch = exit)
            re_patch_off(c, sp, c.code_len - sp);
        }
    } else if (mx > mn) {
        int rem = mx - mn;
        if (rem > 15) rem = 15;
        int[16] sps;
        if (lazy) {
            for (int i = 0; i < rem; i++) {
                sps[i] = c.code_len;
                re_emit3(c, ReOp.SPLIT, 0);
                libc::memcpy(c.code + c.code_len, &abc, (usz)alen);
                c.code_len += alen;
            }
            for (int i = 0; i < rem; i++) re_patch_off(c, sps[i], c.code_len - sps[i]);
        } else {
            for (int i = 0; i < rem; i++) {
                libc::memcpy(c.code + c.code_len, &abc, (usz)alen);
                c.code_len += alen;
                sps[i] = c.code_len;
                re_emit3(c, ReOp.SPLIT, 0);
            }
            for (int i = 0; i < rem; i++) re_patch_off(c, sps[i], 3);
        }
    }
    return 1;
}

fn int? re_parse_seq(ReCompiler* c) {
    while (!re_at_end(c) && re_peek(c) != '|' && re_peek(c) != ')') {
        int? r = re_parse_quant(c);
        if (catch e = r) return r;
        if (r == 0) break;
    }
    return 1;
}

fn int? re_parse_alt(ReCompiler* c) {
    int? sr = re_parse_seq(c);
    if (catch e = sr) return sr;
    if (re_at_end(c) || re_peek(c) != '|') return 1;

    // Save first alternative
    char[4096] saved;
    int saved_len = c.code_len;
    libc::memcpy(&saved, c.code, (usz)saved_len);
    c.code_len = 0;

    int[16] alt_off;
    int[16] alt_len_arr;
    int nalt = 1;
    alt_off[0] = 0;
    alt_len_arr[0] = saved_len;

    while (!re_at_end(c) && re_peek(c) == '|') {
        c.pos++;
        int before = c.code_len;
        int? sr2 = re_parse_seq(c);
        if (catch e = sr2) return sr2;
        alt_off[nalt] = before;
        alt_len_arr[nalt] = c.code_len - before;
        nalt++;
    }

    // Save all alternatives
    char[4096] all;
    int all_len = c.code_len;
    libc::memcpy(&all, c.code, (usz)all_len);
    c.code_len = 0;

    for (int i = 0; i < nalt; i++) {
        int aoff = alt_off[i];
        int alen_i = alt_len_arr[i];

        if (i < nalt - 1) {
            int sp = c.code_len;
            re_emit3(c, ReOp.SPLIT, 0); // patch after alt+JMP
            if (i == 0) {
                libc::memcpy(c.code + c.code_len, &saved, (usz)alen_i);
            } else {
                libc::memcpy(c.code + c.code_len, &all + aoff, (usz)alen_i);
            }
            c.code_len += alen_i;
            re_emit3(c, ReOp.JMP, 0); // patch later to end
            // SPLIT: first=pc+3=this_alt, second=next_alt(after JMP)
            re_patch_off(c, sp, c.code_len - sp);
        } else {
            if (i == 0) {
                libc::memcpy(c.code + c.code_len, &saved, (usz)alen_i);
            } else {
                libc::memcpy(c.code + c.code_len, &all + aoff, (usz)alen_i);
            }
            c.code_len += alen_i;
        }
    }

    // Patch JMP offsets to point to end
    for (int i = 0; i < c.code_len; i++) {
        char op = c.code[i];
        if (op == (char)ReOp.JMP) {
            int off = re_read_off(c.code, i);
            if (off == 0) re_patch_off(c, i, c.code_len - i);
            i += 2;
        } else if (op == (char)ReOp.SPLIT || op == (char)ReOp.SAVE) {
            i += 2;
        } else if (op == (char)ReOp.MATCH_CHAR || op == (char)ReOp.MATCH_CHAR_CI || op == (char)ReOp.MATCH_CLASS) {
            i += 1;
        }
    }

    return 1;
}

fn ReCompiled*? tiny_re_compile(char* pattern, usz pattern_len,
                                 int flags, char* error_msg, int error_msg_size) {
    char* code_buf = (char*)libc::malloc(4096);
    char* cls_buf = (char*)libc::malloc(512);
    if (code_buf == null || cls_buf == null) {
        if (code_buf != null) libc::free(code_buf);
        if (cls_buf != null) libc::free(cls_buf);
        return types::ALLOC_ERROR~;
    }

    ReCompiler c;
    libc::memset(&c, 0, ReCompiler::size);
    c.pattern = pattern;
    c.pat_len = (int)pattern_len;
    c.flags = flags;
    c.next_group = 1;
    c.code = code_buf;
    c.code_cap = 4096;
    c.classes = cls_buf;

    re_emit3(&c, ReOp.SAVE, 0);
    int? result = re_parse_alt(&c);
    bool ok = true;
    if (catch e = result) { ok = false; }
    if (ok && !re_at_end(&c)) { ok = false; }
    if (ok) {
        re_emit3(&c, ReOp.SAVE, 1);
        re_emit_op(&c, ReOp.ACCEPT);
    }

    if (!ok) {
        libc::free(code_buf);
        libc::free(cls_buf);
        if (error_msg != null && error_msg_size > 0) {
            libc::strncpy(error_msg, "regexp compile error", (usz)(error_msg_size - 1));
            error_msg[error_msg_size - 1] = 0;
        }
        return null;
    }

    int cls_size = c.class_count * 32;
    int total = (int)ReCompiled::size + c.code_len + cls_size;
    void* raw = libc::malloc((usz)total);
    if (raw == null) {
        libc::free(code_buf);
        libc::free(cls_buf);
        return types::ALLOC_ERROR~;
    }
    libc::memset(raw, 0, (usz)total);

    ReCompiled* re = (ReCompiled*)raw;
    re.code = (char*)raw + (int)ReCompiled::size;
    re.code_len = c.code_len;
    re.num_captures = c.next_group;
    re.flags = flags;
    libc::memcpy(re.code, code_buf, (usz)c.code_len);
    if (c.class_count > 0) {
        re.classes = re.code + c.code_len;
        libc::memcpy(re.classes, cls_buf, (usz)cls_size);
    }
    libc::free(code_buf);
    libc::free(cls_buf);
    if (error_msg != null && error_msg_size > 0) error_msg[0] = 0;
    return re;
}

fn bool re_run(char* code, int code_len, char* classes,
               char* input, int input_len, int flags,
               int* caps, int ncaps, int pc, int sp) {
    while (pc < code_len) {
        char op = code[pc];
        if (op == (char)ReOp.MATCH_CHAR) {
            if (sp >= input_len || input[sp] != code[pc + 1]) return false;
            pc += 2; sp++;
        }
        else if (op == (char)ReOp.MATCH_CHAR_CI) {
            if (sp >= input_len || !re_eq_ci(input[sp], code[pc + 1])) return false;
            pc += 2; sp++;
        }
        else if (op == (char)ReOp.MATCH_ANY) {
            if (sp >= input_len || input[sp] == '\n') return false;
            pc++; sp++;
        }
        else if (op == (char)ReOp.MATCH_ANY_ALL) {
            if (sp >= input_len) return false;
            pc++; sp++;
        }
        else if (op == (char)ReOp.MATCH_CLASS) {
            if (sp >= input_len) return false;
            int ci = (int)(usz)code[pc + 1];
            if (!cls_test(classes + ci * 32, (int)(usz)input[sp])) return false;
            pc += 2; sp++;
        }
        else if (op == (char)ReOp.MATCH_START) {
            bool ok = (sp == 0);
            if (!ok && (flags & RE_FLAG_MULTILINE)) ok = (input[sp - 1] == '\n');
            if (!ok) return false;
            pc++;
        }
        else if (op == (char)ReOp.MATCH_END) {
            bool ok = (sp >= input_len);
            if (!ok && (flags & RE_FLAG_MULTILINE)) ok = (input[sp] == '\n');
            if (!ok) return false;
            pc++;
        }
        else if (op == (char)ReOp.SPLIT) {
            int off = re_read_off(code, pc);
            if (re_run(code, code_len, classes, input, input_len, flags, caps, ncaps, pc + 3, sp)) return true;
            return re_run(code, code_len, classes, input, input_len, flags, caps, ncaps, pc + off, sp);
        }
        else if (op == (char)ReOp.JMP) {
            pc = pc + re_read_off(code, pc);
        }
        else if (op == (char)ReOp.SAVE) {
            int slot = re_read_off(code, pc);
            if (slot < 0 || slot >= ncaps) return false;
            int old = caps[slot];
            caps[slot] = sp;
            if (re_run(code, code_len, classes, input, input_len, flags, caps, ncaps, pc + 3, sp)) return true;
            caps[slot] = old;
            return false;
        }
        else if (op == (char)ReOp.ACCEPT) {
            return true;
        }
        else {
            return false;
        }
    }
    return false;
}

fn int tiny_re_exec(ReCompiled* re, char* input, int input_len,
                    int start_offset,
                    int* out_start, int* out_end, int* out_num_captures,
                    int* caps_start, int* caps_end, int max_captures) {
    if (re == null) return RE_ERROR;
    int[RE_MAX_CAPTURES * 2] caps;
    int ncaps = re.num_captures * 2;
    if (ncaps > RE_MAX_CAPTURES * 2) ncaps = RE_MAX_CAPTURES * 2;

    for (int sp = start_offset; sp <= input_len; sp++) {
        for (int i = 0; i < ncaps; i++) caps[i] = -1;
        if (re_run(re.code, re.code_len, re.classes, input, input_len, re.flags,
                   &caps, ncaps, 0, sp)) {
            if (out_start) *out_start = caps[0];
            if (out_end) *out_end = caps[1];
            if (out_num_captures) *out_num_captures = re.num_captures - 1;
            for (int i = 1; i < re.num_captures && (i - 1) < max_captures; i++) {
                if (caps_start) caps_start[i - 1] = caps[i * 2];
                if (caps_end) caps_end[i - 1] = caps[i * 2 + 1];
            }
            return RE_MATCH;
        }
        if (re.code[0] == (char)ReOp.MATCH_START && !(re.flags & RE_FLAG_MULTILINE)) break;
    }
    return RE_NO_MATCH;
}

fn void tiny_re_free(ReCompiled* re) {
    if (re != null) libc::free(re);
}
