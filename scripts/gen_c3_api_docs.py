#!/usr/bin/env python3
"""Render the C3 internal API reference as static HTML.

Runs `c3c docgen --json` (stdlib excluded) and writes one page per module to
docs/site/reference/c3-api/, plus an index, using the docs site's layout and
stylesheet. Nothing is rendered at load time and no JavaScript is involved.

    python3 scripts/gen_c3_api_docs.py
    python3 scripts/gen_c3_api_docs.py --json docs.json   # reuse a dump
"""
import argparse
import html
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "site", "reference", "c3-api")

BRAND_SVG = (
    '<svg viewBox="0 0 12 12" width="18" height="18" shape-rendering="crispEdges" aria-hidden="true">'
    '<g fill="currentColor"><rect x="3" y="0" width="1" height="1"/><rect x="8" y="0" width="1" height="1"/>'
    '<rect x="2" y="1" width="2" height="1"/><rect x="8" y="1" width="2" height="1"/><rect x="2" y="2" width="8" height="1"/>'
    '<rect x="2" y="3" width="1" height="1"/><rect x="9" y="3" width="1" height="1"/><rect x="2" y="4" width="1" height="1"/>'
    '<rect x="9" y="4" width="1" height="1"/><rect x="2" y="5" width="1" height="1"/><rect x="4" y="5" width="1" height="1"/>'
    '<rect x="7" y="5" width="1" height="1"/><rect x="9" y="5" width="1" height="1"/><rect x="2" y="6" width="1" height="1"/>'
    '<rect x="9" y="6" width="1" height="1"/><rect x="1" y="7" width="2" height="1"/><rect x="9" y="7" width="2" height="1"/>'
    '<rect x="2" y="8" width="1" height="1"/><rect x="9" y="8" width="1" height="1"/><rect x="2" y="9" width="8" height="1"/></g>'
    '<g fill="currentColor" opacity=".4"><rect x="5" y="6" width="2" height="1"/></g></svg>'
)

SECTIONS = [
    ("types", "Types"),
    ("variables", "Constants & globals"),
    ("functions", "Functions"),
    ("macros", "Macros"),
]

esc = html.escape


def load(json_path):
    if json_path:
        with open(json_path) as f:
            return json.load(f)["modules"]
    out = subprocess.run(
        ["c3c", "docgen", "--json", "--emit-stdlib=no"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)["modules"]


def page_name(module):
    return module.replace("::", "-") + ".html"


class Linker:
    """Maps docgen uids to page#anchor links."""

    def __init__(self, modules):
        self.targets = {}
        for mod, m in modules.items():
            for sec in ("types", "functions", "macros", "variables", "methods", "macro_methods"):
                for e in m.get(sec, []):
                    self.targets[e["uid"]] = (mod, anchor(e))

    def type_ref(self, t, here):
        if t is None:
            return ""
        name = esc(t["name"])
        target = self.targets.get(t.get("uid", ""))
        if not target:
            return name
        mod, anc = target
        href = ("" if mod == here else page_name(mod)) + "#" + anc
        return f'<a href="{href}">{name}</a>'


def anchor(e):
    uid = e["uid"]
    return uid.rsplit("::", 1)[-1]


def generics(e):
    gp = e.get("generic_parameters")
    return f" &lt;{esc(', '.join(gp))}&gt;" if gp else ""


def attrs(e):
    a = e.get("attributes")
    return " " + esc(" ".join(a)) if a else ""


def params(e, link, here):
    out = []
    for p in e.get("members", []):
        parts = []
        if "type" in p:
            parts.append(link.type_ref(p["type"], here))
        if p.get("name"):
            parts.append(esc(p["name"]))
        s = " ".join(parts)
        if "default_value" in p:
            s += " = " + esc(p["default_value"])
        out.append(s)
    return ", ".join(out)


def callable_sig(e, link, here, owner=None):
    kw = "macro" if e["kind"].startswith("macro") else "fn"
    ret = e.get("return_type")
    ret_s = link.type_ref(ret, here) + " " if ret else ""
    name = (esc(owner) + "." if owner else "") + esc(e["name"])
    return f"{kw} {ret_s}{name}{generics(e)}({params(e, link, here)}){attrs(e)}"


def type_block(e, link, here):
    kind = e["kind"]
    name = esc(e["name"]) + generics(e)
    base = e.get("base_type")
    if kind == "alias":
        if base:
            return f"alias {name} = {link.type_ref(base, here)}"
        return f"alias {name} = fn {link.type_ref(e.get('return_type'), here)}({params(e, link, here)})"
    if kind == "distinct type":
        return f"typedef {name} = {link.type_ref(base, here)}"
    if kind == "fault":
        return f"faultdef {name}"
    head = {"enum": "enum", "bitstruct": "bitstruct", "union": "union"}.get(kind, "struct")
    head = f"{head} {name}"
    if kind == "enum":
        assoc = e.get("associated_values")
        inner = link.type_ref(base, here) if base else ""
        if assoc:
            inner += (" " if inner else "") + "(" + ", ".join(
                link.type_ref(a.get("type"), here) + " " + esc(a["name"]) for a in assoc) + ")"
        if inner:
            head += " : " + inner
        lines = []
        for m in e.get("members", []):
            v = m.get("value")
            vs = " { " + ", ".join(esc(x) for x in v) + " }" if v else ""
            lines.append(f"  {esc(m['name'])}{vs},")
        return head + " {\n" + "\n".join(lines) + "\n}"
    if kind == "bitstruct" and base:
        head += " : " + link.type_ref(base, here)
    lines = struct_members(e.get("members", []), link, here, "  ")
    return head + " {\n" + "\n".join(lines) + "\n}" if lines else head + " {}"


def struct_members(members, link, here, indent):
    lines = []
    for m in members:
        if "type" not in m and "members" in m:
            # Anonymous inline struct or union.
            lines.append(f"{indent}{esc(m.get('kind', 'struct'))} {esc(m.get('name', ''))}".rstrip() + " {")
            lines += struct_members(m["members"], link, here, indent + "  ")
            lines.append(f"{indent}}}")
            continue
        parts = []
        if "type" in m:
            parts.append(link.type_ref(m["type"], here))
        if m.get("name"):
            parts.append(esc(m["name"]))
        br = m.get("bit_range")
        bits = f" : {br[0]}..{br[1]}" if br else ""
        lines.append(f"{indent}{' '.join(parts)}{bits};")
    return lines


def var_sig(e, link, here):
    kw = "const " if e.get("is_const") else ""
    v = e.get("value")
    val = " = " + esc(v) if v is not None else ""
    return f"{kw}{link.type_ref(e.get('type'), here)} {esc(e['name'])}{val};"


def docs_html(e):
    d = e.get("docs")
    if not d or not d.get("text"):
        return ""
    return f'<p class="api-desc">{esc(" ".join(d["text"].split()))}</p>'


def src(e):
    return f'<p class="api-src">{esc(e["file"])}{" · private" if e.get("visibility") else ""}</p>'


def item(e, sig, pre=False):
    body = f"<pre><code>{sig}</code></pre>" if pre else f'<p class="api-sig"><code>{sig}</code></p>'
    return f'<div class="api-item" id="{esc(anchor(e))}">{body}{docs_html(e)}{src(e)}</div>'


def head(title, depth_prefix, sidebar, wide=True):
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{esc(title)} · boomkat docs</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&display=swap">
  <link rel="stylesheet" href="{depth_prefix}style.css">
</head>
<body class="has-sidebar">
  <header class="site-head">
    <a class="brand" href="{depth_prefix}index.html">
      {BRAND_SVG}
      <span>boomkat</span>
    </a>
    <nav class="nav-links">
      <a href="{depth_prefix}tutorials/first-script.html">tutorials</a>
      <a href="{depth_prefix}how-to/build-profiles.html">how-to</a>
      <a href="{depth_prefix}reference/c-api.html" aria-current="page">reference</a>
      <a href="{depth_prefix}architecture/architecture.html">architecture</a>
    </nav>
  </header>

  <div class="ref-layout">
    <aside class="ref-sidebar" aria-label="C3 modules">
{sidebar}
    </aside>

    <main class="ref-content">
"""


def foot(prefix):
    return f"""    </main>
  </div>

  <footer class="site-foot">
    <div class="wrap">
      <div class="foot-bar">
        <span><a href="{prefix}index.html">boomkat docs</a> · generated by c3c docgen</span>
        <span class="eof">eof</span>
      </div>
    </div>
  </footer>
</body>
</html>
"""


def sidebar(modules, current, sections):
    out = []
    if sections:
        out.append('      <p class="label">On this page</p>\n      <ul>')
        for anc, title in sections:
            out.append(f'        <li><a href="#{anc}">{esc(title)}</a></li>')
        out.append("      </ul>")
    out.append('      <p class="label">Modules</p>\n      <ul>')
    out.append('        <li><a href="index.html">Overview</a></li>')
    for mod in modules:
        cur = ' aria-current="page"' if mod == current else ""
        out.append(f'        <li><a href="{page_name(mod)}"{cur}>{esc(mod)}</a></li>')
    out.append("      </ul>")
    out.append('      <p class="label">Other Reference</p>\n      <ul>')
    out.append('        <li><a href="../c-api.html">C Embedding API</a></li>')
    out.append('        <li><a href="../cli-and-flags.html">CLI &amp; Build Flags</a></li>')
    out.append("      </ul>")
    return "\n".join(out)


def counts(m):
    return {sec: len(m.get(sec, [])) for sec in ("types", "functions", "methods", "macros", "macro_methods", "variables")}


def render_module(mod, m, modules, link):
    methods = {}
    for sec in ("methods", "macro_methods"):
        for e in m.get(sec, []):
            owner = e["uid"].rsplit("::", 1)[-1].split(".")[0]
            methods.setdefault(owner, []).append(e)

    body = []
    present = []
    type_names = {t["name"] for t in m.get("types", [])}
    for sec, title in SECTIONS:
        items = sorted(m.get(sec, []), key=lambda e: e["name"].lower())
        if sec == "types":
            orphans = sorted(set(methods) - type_names)
        else:
            orphans = []
        if not items and not orphans:
            continue
        sid = "sec-" + sec
        present.append((sid, title))
        body.append(f'      <h2 id="{sid}">{title}</h2>')
        for e in items:
            if sec == "types":
                body.append(item(e, type_block(e, link, mod), pre=True))
                for me in sorted(methods.get(e["name"], []), key=lambda x: x["name"]):
                    body.append(item(me, callable_sig(me, link, mod, e["name"])))
            elif sec == "variables":
                body.append(item(e, var_sig(e, link, mod)))
            else:
                body.append(item(e, callable_sig(e, link, mod)))
        for owner in orphans:
            body.append(f"      <h3>Extensions of <code>{esc(owner)}</code></h3>")
            for me in sorted(methods[owner], key=lambda x: x["name"]):
                body.append(item(me, callable_sig(me, link, mod, owner)))

    c = counts(m)
    gp = m.get("generic_parameters")
    gen = f" &lt;{esc(', '.join(gp))}&gt;" if gp else ""
    intro = (
        f'      <p class="label">reference · c3 internal api</p>\n'
        f"      <h1><code>module {esc(mod)}{gen}</code></h1>\n"
        f'      <p class="lede">{c["types"]} types, {c["functions"] + c["macros"]} functions and macros, '
        f'{c["methods"] + c["macro_methods"]} methods, {c["variables"]} constants and globals.</p>\n'
        f'      <div class="band" aria-hidden="true"></div>\n'
    )
    return (head(mod, "../../", sidebar(modules, mod, present)) + intro + "\n".join(body) + "\n" + foot("../../"))


def render_index(modules):
    rows = []
    for mod, m in modules.items():
        c = counts(m)
        rows.append(
            f'        <tr><td><a href="{page_name(mod)}">{esc(mod)}</a></td>'
            f'<td>{c["types"]}</td><td>{c["functions"] + c["macros"]}</td>'
            f'<td>{c["methods"] + c["macro_methods"]}</td><td>{c["variables"]}</td></tr>'
        )
    intro = """      <p class="label">reference</p>
      <h1>C3 internal API</h1>
      <p class="lede">
        Every module in the engine source, generated from <code>c3c docgen</code> by
        <code>scripts/gen_c3_api_docs.py</code>. These are internals, so they change without notice.
        Embedders should use the <a href="../c-api.html">C embedding API</a> or the
        <code>boomkat::embed</code> module.
      </p>
      <div class="band" aria-hidden="true"></div>
      <table>
        <thead><tr><th>Module</th><th>Types</th><th>Functions</th><th>Methods</th><th>Constants</th></tr></thead>
        <tbody>
"""
    return (head("C3 internal API", "../../", sidebar(modules, None, None)) + intro
            + "\n".join(rows) + "\n        </tbody>\n      </table>\n" + foot("../../"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", help="read a docgen JSON dump instead of running c3c")
    args = ap.parse_args()

    raw = load(args.json)
    modules = {k: raw[k] for k in sorted(raw) if not k.startswith("std::")}
    link = Linker(modules)

    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    with open(os.path.join(OUT, "index.html"), "w") as f:
        f.write(render_index(modules))
    for mod, m in modules.items():
        with open(os.path.join(OUT, page_name(mod)), "w") as f:
            f.write(render_module(mod, m, modules, link))
    print(f"wrote {len(modules) + 1} pages to {os.path.relpath(OUT, ROOT)}", file=sys.stderr)


if __name__ == "__main__":
    main()
