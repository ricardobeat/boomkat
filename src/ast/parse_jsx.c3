// JSX (classic runtime). An element lowers to a call during parsing, so no later stage sees it:
//
//   <a x="1" {...p}>t{e}</a>   ->   factory("a", { "x": "1", ...p }, "t", e)
//   <>..</>                    ->   factory(fragment, null, ...)
//
// The factory and fragment expressions come from `@jsx` / `@jsxFrag` pragma comments at the top of
// the file and default to `React.createElement` / `React.Fragment`. Tag, attribute and text
// scanning works on the source directly, because JSX text and attribute strings are not JS tokens;
// only the `{...}` expression containers go through the token stream.
module boomkat::ast;

import boomkat::lexer;

const String JSX_DEFAULT_FACTORY = "React.createElement";
const String JSX_DEFAULT_FRAGMENT = "React.Fragment";

fn bool jsx_is_space(char c) @inline => c == ' ' || c == '\t' || c == '\n' || c == '\r';

fn bool jsx_is_name_char(char c) @inline {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$' || c == '.';
}

// Read the `@jsx` and `@jsxFrag` pragmas from the comments that open the file.
fn void Parser.jsx_pragmas(&self) {
    self.jsx_factory = JSX_DEFAULT_FACTORY;
    self.jsx_fragment = JSX_DEFAULT_FRAGMENT;
    char[] src = self.lex.source;
    usz i = self.lex.pos;
    while (i < src.len) {
        if (jsx_is_space(src[i])) { i++; continue; }
        if (i + 1 >= src.len || src[i] != '/' || (src[i + 1] != '/' && src[i + 1] != '*')) return;
        bool block = src[i + 1] == '*';
        usz end = i + 2;
        while (end < src.len && (block ? !(src[end] == '*' && end + 1 < src.len && src[end + 1] == '/') : src[end] != '\n')) end++;
        for (usz j = i + 2; j < end; j++) {
            if (src[j] != '@') continue;
            usz w = j + 1;
            while (w < end && src[w] >= 'A' && src[w] <= 'z') w++;
            char[] word = src[j + 1:w - j - 1];
            if (word != "jsx" && word != "jsxFrag") continue;
            while (w < end && (src[w] == ' ' || src[w] == '\t')) w++;
            usz v = w;
            while (v < end && jsx_is_name_char(src[v])) v++;
            if (v == w) continue;
            if (word == "jsx") { self.jsx_factory = src[w:v - w]; } else { self.jsx_fragment = src[w:v - w]; }
            j = v;
        }
        i = block ? end + 2 : end;
    }
}

// ---- scanning ----

// Continue token scanning at byte `pos`.
fn void? Parser.jsx_resume(&self, uint pos) {
    SourcePos sp = self.ast.position(pos);
    Token t;
    t.pos = pos;
    t.line = sp.line;
    t.col = sp.col;
    self.lex.seek_to_token(t);
    self.has_peek = false;
    self.peek_failed = false;
    self.next()!;
}

// The current token starts with `>`; the lexer may have fused it with what follows.
fn bool Parser.jsx_at_gt(&self) {
    return self.tok.pos < self.lex.source.len && self.lex.source[self.tok.pos] == '>';
}

// Append the UTF-8 encoding of `cp` to `out`.
fn usz jsx_utf8(char[] out, usz n, uint cp) {
    if (cp < 0x80) {
        out[n++] = (char)cp;
    } else if (cp < 0x800) {
        out[n++] = (char)(0xC0 | (cp >> 6));
        out[n++] = (char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out[n++] = (char)(0xE0 | (cp >> 12));
        out[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[n++] = (char)(0x80 | (cp & 0x3F));
    } else {
        out[n++] = (char)(0xF0 | (cp >> 18));
        out[n++] = (char)(0x80 | ((cp >> 12) & 0x3F));
        out[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[n++] = (char)(0x80 | (cp & 0x3F));
    }
    return n;
}

// Copy `src[s:e]` to `out` at `n`, decoding `&amp;`-style entities (the XML five, `&nbsp;`, and
// numeric references). An unknown entity stays as written. The output never outgrows the input.
fn usz jsx_copy(char[] src, usz s, usz e, char[] out, usz n) {
    while (s < e) {
        char c = src[s];
        usz semi = s + 1;
        while (c == '&' && semi < e && semi - s < 10 && src[semi] != ';') semi++;
        if (c != '&' || semi >= e || src[semi] != ';') { out[n++] = c; s++; continue; }
        char[] name = src[s + 1:semi - s - 1];
        uint cp = 0;
        if (name == "amp") { cp = '&'; }
        else if (name == "lt") { cp = '<'; }
        else if (name == "gt") { cp = '>'; }
        else if (name == "quot") { cp = '"'; }
        else if (name == "apos") { cp = '\''; }
        else if (name == "nbsp") { cp = 0xA0; }
        else if (name.len > 1 && name[0] == '#') {
            bool hex = name[1] == 'x';
            for (usz k = hex ? 2 : 1; k < name.len; k++) {
                char d = name[k];
                uint v = d >= '0' && d <= '9' ? d - '0' : hex && d >= 'a' && d <= 'f' ? d - 'a' + 10 : hex && d >= 'A' && d <= 'F' ? d - 'A' + 10 : 99;
                if (v >= (hex ? 16 : 10) || cp > 0x10FFFF) { cp = 0; break; }
                cp = cp * (hex ? 16 : 10) + v;
            }
        }
        if (cp == 0 || cp > 0x10FFFF) { out[n++] = c; s++; continue; }
        n = jsx_utf8(out, n, cp);
        s = semi + 1;
    }
    return n;
}

// The decoded value of `src[a:b]`, in lexer-owned storage. With `lines`, it is JSX text: each line
// loses its leading and trailing blanks (except at the ends of the span), blank lines vanish, and
// the rest join with single spaces.
fn char[] Parser.jsx_decode(&self, uint a, uint b, bool lines) {
    if (a >= b) return "";
    char[] src = self.lex.source;
    char[] out = self.lex.arena_alloc((usz)(b - a));
    if (out.len == 0) return "";
    usz n = 0;
    if (!lines) return out[:jsx_copy(src, a, b, out, 0)];
    usz at = a;
    while (at <= b) {
        usz e = at;
        while (e < b && src[e] != '\n' && src[e] != '\r') e++;
        usz s = at;
        usz le = e;
        if (at != a) while (s < le && (src[s] == ' ' || src[s] == '\t')) s++;
        if (e != b) while (le > s && (src[le - 1] == ' ' || src[le - 1] == '\t')) le--;
        if (s < le) {
            if (n > 0) out[n++] = ' ';
            n = jsx_copy(src, s, le, out, n);
        }
        at = e + (usz)(e + 1 < b && src[e] == '\r' && src[e + 1] == '\n' ? 2 : 1);
    }
    return out[:n];
}

// ---- nodes ----

// `a.b.c` as an identifier reference or member chain; `this` stands for itself.
fn uint Parser.jsx_ref(&self, char[] path, uint pos) {
    uint node = 0;
    usz s = 0;
    while (s <= path.len) {
        usz e = s;
        while (e < path.len && path[e] != '.') e++;
        char[] seg = path[s:e - s];
        if (node == 0) {
            node = seg == "this" ? self.node(NodeTag.THIS, pos) : self.node(NodeTag.IDENT, pos, self.atom(seg));
        } else {
            node = self.node(NodeTag.MEMBER, pos, node, self.atom(seg));
        }
        s = e + 1;
    }
    return node;
}

fn uint Parser.jsx_string(&self, char[] s, uint pos) {
    return self.node(NodeTag.STRING, pos, self.atom(s));
}

// A tag, attribute or closing-tag name: identifiers joined by `.` or `:` (blanks allowed around
// them) or `-` (nothing between). Returns its text without the blanks.
fn char[]? Parser.jsx_name(&self) {
    char[] src = self.lex.source;
    uint start = self.tok.pos;
    uint end = start;
    bool blanks = false;
    bool want_name = true;
    for (;;) {
        TokenType tt = self.tok.type;
        bool joiner = tt == TokenType.DOT || tt == TokenType.COLON || (tt == TokenType.MINUS && self.tok.pos == end);
        if (!(want_name ? is_name_token(tt) : joiner)) break;
        blanks = blanks || self.tok.pos != end && end != start;
        end = self.tok.end;
        want_name = !want_name;
        self.next()!;
    }
    if (want_name) return self.unexpected()~;
    if (!blanks) return src[start:end - start];
    char[] out = self.lex.arena_alloc((usz)(end - start));
    usz n = 0;
    for (uint k = start; k < end; k++) if (!jsx_is_space(src[k])) out[n++] = src[k];
    return out[:n];
}

// `{ expression }` or a spread child `{ ...expression }` with the cursor just past the `{`. Leaves the current token on the `}`; an
// empty container (`{}` or only a comment) yields 0.
fn uint? Parser.jsx_container(&self, uint after_brace) {
    self.jsx_resume(after_brace)!;
    if (self.tok.type == TokenType.RBRACE) return 0;
    bool saved = self.no_in;
    self.no_in = false;
    uint at = self.tok.pos;
    bool spread = self.tok.type == TokenType.ELLIPSIS;
    if (spread) self.next()!;
    uint e = self.assign_expr()!;
    if (spread) e = self.node(NodeTag.SPREAD, at, e);
    self.no_in = saved;
    if (self.tok.type != TokenType.RBRACE) return self.unexpected()~;
    return e;
}

// ---- elements ----

// Parse the element at the current `<`. Leaves the current token on its closing `>`.
fn uint? Parser.jsx_element(&self) {
    self.check_stack()!;
    char[] src = self.lex.source;
    uint pos = self.tok.pos;
    self.next()!;
    char[] name = {};
    uint tag;
    if (self.jsx_at_gt()) {
        tag = self.jsx_ref(self.jsx_fragment, pos);
    } else {
        name = self.jsx_name()!;
        bool plain = name[0] >= 'a' && name[0] <= 'z';
        bool member = false;
        for (usz i = 0; i < name.len; i++) {
            plain = plain || name[i] == '-' || name[i] == ':';
            member = member || name[i] == '.';
        }
        plain = plain && !member;
        tag = plain ? self.jsx_string(name, pos) : self.jsx_ref(name, pos);
    }

    uint props = 0;
    uint mark = self.scratch_mark();
    while (!self.jsx_at_gt() && self.tok.type != TokenType.SLASH) {
        uint at = self.tok.pos;
        if (self.tok.type == TokenType.LBRACE) {
            self.next()!;
            self.expect(TokenType.ELLIPSIS)!;
            uint arg = self.assign_expr()!;
            if (self.tok.type != TokenType.RBRACE) return self.unexpected()~;
            self.scratch_push(self.node(NodeTag.PROP_SPREAD, at, arg));
            self.next()!;
            continue;
        }
        char[] attr = self.jsx_name()!;
        uint value = self.node(NodeTag.TRUE_LIT, at);
        if (self.tok.type == TokenType.ASSIGN) {
            uint v = self.tok.end;
            while (v < src.len && jsx_is_space(src[v])) v++;
            if (v >= src.len) return self.unexpected()~;
            if (src[v] == '"' || src[v] == '\'') {
                uint close = v + 1;
                while (close < src.len && src[close] != src[v]) close++;
                if (close >= src.len) return self.fail_at(v, "unterminated JSX attribute string")~;
                value = self.jsx_string(self.jsx_decode(v + 1, close, false), v);
                self.jsx_resume(close + 1)!;
            } else if (src[v] == '{') {
                value = self.jsx_container(v + 1)!;
                if (value == 0) return self.fail_at(v, "JSX attribute value is empty")~;
                self.next()!;
            } else {
                return self.fail_at(v, "JSX attribute value must be a string or an expression")~;
            }
        }
        self.scratch_push(self.node(NodeTag.PROP_INIT, at, self.jsx_string(attr, at), value));
    }
    props = self.ast.add_list(self.scratch.data[mark:self.scratch.len - mark]);
    uint nprops = self.ast.list_len(props);
    self.scratch.truncate(mark);
    uint props_node = nprops == 0 ? self.node(NodeTag.NULL_LIT, pos) : self.node(NodeTag.OBJECT, pos, props);

    mark = self.scratch_mark();
    self.scratch_push(tag);
    self.scratch_push(props_node);
    if (self.tok.type == TokenType.SLASH) {
        self.next()!;
        if (!self.jsx_at_gt()) return self.unexpected()~;
    } else {
        uint cursor = self.tok.pos + 1;
        for (;;) {
            uint j = cursor;
            while (j < src.len && src[j] != '<' && src[j] != '{') j++;
            if (j >= src.len) return self.fail_at(pos, "unterminated JSX element")~;
            char[] text = self.jsx_decode(cursor, j, true);
            if (text.len > 0) self.scratch_push(self.jsx_string(text, cursor));
            if (src[j] == '{') {
                uint e = self.jsx_container(j + 1)!;
                if (e != 0) self.scratch_push(e);
                cursor = self.tok.pos + 1;
                continue;
            }
            uint k = j + 1;
            while (k < src.len && jsx_is_space(src[k])) k++;
            self.jsx_resume(k < src.len && src[k] == '/' ? k + 1 : j)!;
            if (k >= src.len || src[k] != '/') {
                self.scratch_push(self.jsx_element()!);
                cursor = self.tok.pos + 1;
                continue;
            }
            char[] close = self.jsx_at_gt() ? (char[]){} : self.jsx_name()!;
            if (close != name) return self.fail_at(j, "mismatched JSX closing tag")~;
            if (!self.jsx_at_gt()) return self.unexpected()~;
            break;
        }
    }
    uint args = self.scratch_list(mark);
    return self.node(NodeTag.CALL, pos, self.jsx_ref(self.jsx_factory, pos), args);
}

// An element in expression position: the token after its closing `>` is scanned as JS.
fn uint? Parser.jsx_expr(&self) {
    uint e = self.jsx_element()!;
    self.jsx_resume(self.tok.pos + 1)!;
    return e;
}
