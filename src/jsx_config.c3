// JSX options from the nearest tsconfig.json or jsconfig.json.
//
// The files are JSONC (comments allowed), so a full JSON parse is not needed: the four compiler
// options that matter are string values, found by key. `extends` is not followed.
module boomkat::jsx_config;

import boomkat::lexer;
import std::io;

// The text of the nearest `tsconfig.json` or `jsconfig.json` above `module_path`, searching its
// directory first and then each parent. Returns an empty slice when there is none; the caller
// frees a non-empty result.
fn char[] find(char[] module_path) {
    String[2] names = { "tsconfig.json", "jsconfig.json" };
    usz end = module_path.len;
    for (;;) {
        sz slash = (sz)end - 1;
        while (slash >= 0 && module_path[slash] != '/') slash--;
        String dir = (String)module_path[:(usz)(slash + 1)];
        foreach (name : names) {
            if (try text = file::load(mem, string::tformat("%s%s", dir, name))) {
                if (text.len > 0) return text;
                mem::free(text.ptr);
            }
        }
        if (slash <= 0) return {};
        end = (usz)slash;
    }
}

// Skip blanks and comments.
fn usz skip_blank(char[] t, usz i) {
    while (i < t.len) {
        if (t[i] == ' ' || t[i] == '\t' || t[i] == '\n' || t[i] == '\r') { i++; continue; }
        if (t[i] != '/' || i + 1 >= t.len) break;
        if (t[i + 1] == '/') {
            while (i < t.len && t[i] != '\n') i++;
        } else if (t[i + 1] == '*') {
            i += 2;
            while (i + 1 < t.len && !(t[i] == '*' && t[i + 1] == '/')) i++;
            i += 2;
        } else {
            break;
        }
    }
    return i < t.len ? i : t.len;
}

// The string starting at the quote `t[i]`: its text, and `i` moves past the closing quote.
fn char[] read_string(char[] t, usz* i) {
    usz start = *i + 1;
    usz at = start;
    while (at < t.len && t[at] != '"') at += t[at] == '\\' ? 2 : 1;
    if (at > t.len) at = t.len;
    *i = at + 1;
    return t[start:at - start];
}

// The JSX options `text` sets. The strings point into `text`.
fn JsxOptions parse(char[] text) {
    JsxOptions o;
    usz i = 0;
    while ((i = skip_blank(text, i)) < text.len) {
        if (text[i] != '"') { i++; continue; }
        char[] key = read_string(text, &i);
        usz at = skip_blank(text, i);
        if (at >= text.len || text[at] != ':') continue;
        at = skip_blank(text, at + 1);
        if (at >= text.len || text[at] != '"') { i = at; continue; }
        i = at;
        char[] value = read_string(text, &i);
        if (key == "jsx") {
            o.runtime = value == "react-jsx" || value == "react-jsxdev" ? JsxRuntime.AUTOMATIC : JsxRuntime.CLASSIC;
        } else if (key == "jsxImportSource") {
            o.import_source = value;
        } else if (key == "jsxFactory") {
            o.factory = value;
        } else if (key == "jsxFragmentFactory") {
            o.fragment = value;
        }
    }
    return o;
}
