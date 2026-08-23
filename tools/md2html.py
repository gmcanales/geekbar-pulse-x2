#!/usr/bin/env python3
"""Render a Markdown file to a single self-contained HTML page.

No dependencies (pandoc and python-markdown aren't installed here), and no
external assets — the output opens straight from the filesystem with no
network. Handles the subset this repo's docs actually use: ATX headings,
pipe tables, fenced code, blockquotes, nested lists, rules, and inline
code/bold/italic.

    ./tools/md2html.py firmware-guide.md firmware-guide.html
"""
import html
import re
import sys

# ---------------------------------------------------------------- inline ----

CODE_TOKEN = "\x00CODE%d\x00"


def inline(text):
    """Escape, then apply inline formatting. Code spans are pulled out first
    so their contents never get treated as emphasis."""
    text = html.escape(text, quote=False)

    spans = []

    def stash(m):
        spans.append(m.group(1))
        return CODE_TOKEN % (len(spans) - 1)

    text = re.sub(r"`([^`]+)`", stash, text)

    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", text)

    for i, s in enumerate(spans):
        text = text.replace(CODE_TOKEN % i, "<code>%s</code>" % s)
    return text


def slug(text):
    s = re.sub(r"<[^>]+>", "", text)
    s = re.sub(r"[^\w\s-]", "", s).strip().lower()
    return re.sub(r"[\s_]+", "-", s) or "section"


# ----------------------------------------------------------------- blocks ---

class Renderer:
    def __init__(self, lines):
        self.lines = lines
        self.i = 0
        self.out = []
        self.toc = []
        self.list_stack = []   # (indent, tag)

    def peek(self, n=0):
        j = self.i + n
        return self.lines[j] if j < len(self.lines) else None

    # --- list handling: indent decides nesting depth ---
    def close_lists(self, to_indent=-1):
        while self.list_stack and self.list_stack[-1][0] > to_indent:
            self.out.append("</%s>" % self.list_stack.pop()[1])
            if self.list_stack:
                self.out.append("</li>")   # close the <li> we were nested in

    def open_list(self, indent, tag):
        # A nested list belongs *inside* the preceding <li>, not beside it,
        # so reopen that item rather than closing it.
        if self.list_stack and self.out and self.out[-1].endswith("</li>"):
            self.out[-1] = self.out[-1][: -len("</li>")]
        self.list_stack.append((indent, tag))
        self.out.append("<%s>" % tag)

    def run(self):
        while self.i < len(self.lines):
            line = self.lines[self.i]

            if line.startswith("```"):
                self.code_fence()
            elif re.match(r"^\s*\|", line) and self.is_table():
                self.table()
            elif re.match(r"^#{1,6} ", line):
                self.heading()
            elif re.match(r"^\s*> ?", line):
                self.blockquote()
            elif re.match(r"^\s*[-*] ", line) or re.match(r"^\s*\d+\. ", line):
                self.list_item()
            elif re.match(r"^-{3,}\s*$", line):
                self.close_lists()
                self.out.append("<hr>")
                self.i += 1
            elif line.strip() == "":
                self.i += 1
            else:
                self.paragraph()

        self.close_lists()
        return "\n".join(self.out), self.toc

    def heading(self):
        self.close_lists()
        m = re.match(r"^(#{1,6}) (.*)$", self.lines[self.i])
        level, text = len(m.group(1)), inline(m.group(2))
        anchor = slug(text)
        if level <= 2:
            self.toc.append((level, re.sub(r"<[^>]+>", "", text), anchor))
        self.out.append(
            '<h%d id="%s"><a class="anchor" href="#%s">%s</a></h%d>'
            % (level, anchor, anchor, text, level)
        )
        self.i += 1

    def code_fence(self):
        self.close_lists()
        lang = self.lines[self.i][3:].strip()
        self.i += 1
        body = []
        while self.i < len(self.lines) and not self.lines[self.i].startswith("```"):
            body.append(self.lines[self.i])
            self.i += 1
        self.i += 1
        cls = ' class="lang-%s"' % lang if lang else ""
        self.out.append(
            "<pre%s><code>%s</code></pre>"
            % (cls, html.escape("\n".join(body), quote=False))
        )

    def is_table(self):
        nxt = self.peek(1) or ""
        return bool(re.match(r"^\s*\|[\s:|-]+\|\s*$", nxt))

    def table(self):
        self.close_lists()

        def cells(row):
            row = row.strip()
            if row.startswith("|"):
                row = row[1:]
            if row.endswith("|"):
                row = row[:-1]
            return [c.strip() for c in row.split("|")]

        header = cells(self.lines[self.i])
        self.i += 2  # header + separator
        rows = []
        while self.i < len(self.lines) and re.match(r"^\s*\|", self.lines[self.i]):
            rows.append(cells(self.lines[self.i]))
            self.i += 1

        parts = ['<div class="table-wrap"><table><thead><tr>']
        parts += ["<th>%s</th>" % inline(c) for c in header]
        parts.append("</tr></thead><tbody>")
        for r in rows:
            parts.append("<tr>" + "".join("<td>%s</td>" % inline(c) for c in r) + "</tr>")
        parts.append("</tbody></table></div>")
        self.out.append("".join(parts))

    def blockquote(self):
        self.close_lists()
        body = []
        while self.i < len(self.lines) and re.match(r"^\s*>", self.lines[self.i]):
            body.append(re.sub(r"^\s*> ?", "", self.lines[self.i]))
            self.i += 1
        inner, _ = Renderer(body).run()
        self.out.append("<blockquote>%s</blockquote>" % inner)

    def list_item(self):
        line = self.lines[self.i]
        indent = len(line) - len(line.lstrip())
        ordered = bool(re.match(r"^\s*\d+\. ", line))
        tag = "ol" if ordered else "ul"
        text = re.sub(r"^\s*(?:[-*]|\d+\.) ", "", line)

        # deeper than the current level -> nest; shallower -> unwind
        if not self.list_stack or indent > self.list_stack[-1][0]:
            self.open_list(indent, tag)
        else:
            self.close_lists(indent)
            if not self.list_stack or self.list_stack[-1][1] != tag:
                self.close_lists(indent - 1)
                self.open_list(indent, tag)

        self.i += 1
        # continuation lines: more-indented text that isn't a new bullet
        cont = []
        while self.i < len(self.lines):
            nxt = self.lines[self.i]
            if nxt.strip() == "" or re.match(r"^\s*(?:[-*]|\d+\.) ", nxt):
                break
            if len(nxt) - len(nxt.lstrip()) <= indent and nxt.strip():
                break
            cont.append(nxt.strip())
            self.i += 1
        if cont:
            text = text + " " + " ".join(cont)
        self.out.append("<li>%s</li>" % inline(text))

    def paragraph(self):
        self.close_lists()
        body = []
        while self.i < len(self.lines):
            line = self.lines[self.i]
            if (line.strip() == "" or line.startswith("```")
                    or re.match(r"^#{1,6} ", line) or re.match(r"^\s*\|", line)
                    or re.match(r"^\s*[-*] ", line) or re.match(r"^\s*\d+\. ", line)
                    or re.match(r"^-{3,}\s*$", line) or re.match(r"^\s*>", line)):
                break
            body.append(line.strip())
            self.i += 1
        if body:
            self.out.append("<p>%s</p>" % inline(" ".join(body)))


# ------------------------------------------------------------------ page ----

CSS = """
:root {
  --bg:#fbfaf8; --fg:#22201d; --muted:#6b665f; --rule:#e2ddd5;
  --card:#ffffff; --code-bg:#f3f0eb; --code-fg:#1e1c1a;
  --pre-bg:#2b2825; --pre-fg:#ececec;
  --accent:#9a4b1f; --accent-soft:#f3e6dc; --shadow:0 1px 2px rgba(0,0,0,.05);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg:#16151a; --fg:#e6e3de; --muted:#9d968c; --rule:#302d36;
    --card:#1d1c22; --code-bg:#26242c; --code-fg:#ecd9c6;
    --pre-bg:#0f0e12; --pre-fg:#e2ded8;
    --accent:#e08c50; --accent-soft:#2c231c; --shadow:none;
  }
}
* { box-sizing:border-box; }
html { scroll-behavior:smooth; }
body {
  margin:0; background:var(--bg); color:var(--fg);
  font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
  -webkit-text-size-adjust:100%;
}
.layout { display:grid; grid-template-columns:280px minmax(0,1fr); gap:0; max-width:1240px; margin:0 auto; }
nav {
  position:sticky; top:0; align-self:start; max-height:100vh; overflow-y:auto;
  padding:2.5rem 1.25rem 3rem; border-right:1px solid var(--rule); font-size:.86rem;
}
nav .toc-title { font-weight:650; color:var(--muted); text-transform:uppercase;
  letter-spacing:.08em; font-size:.7rem; margin-bottom:.9rem; }
nav a { display:block; color:var(--muted); text-decoration:none; padding:.2rem 0;
  border-left:2px solid transparent; padding-left:.7rem; }
nav a:hover { color:var(--accent); border-left-color:var(--accent); }
nav a.lvl1 { color:var(--fg); font-weight:600; margin-top:.85rem; }
nav a.lvl2 { padding-left:1.4rem; }
main { padding:2.5rem 2.5rem 6rem; min-width:0; }
h1,h2,h3,h4 { line-height:1.25; margin:2.4rem 0 .8rem; }
h1 { font-size:1.85rem; letter-spacing:-.02em; padding-bottom:.5rem; border-bottom:2px solid var(--rule); }
h1:first-child { margin-top:0; }
h2 { font-size:1.3rem; letter-spacing:-.01em; margin-top:2.6rem; }
h3 { font-size:1.05rem; color:var(--fg); }
.anchor { color:inherit; text-decoration:none; }
.anchor:hover::after { content:" #"; color:var(--accent); font-weight:400; }
p { margin:.85rem 0; }
a { color:var(--accent); }
code {
  background:var(--code-bg); color:var(--code-fg); padding:.12em .38em;
  border-radius:4px; font-size:.87em;
  font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;
}
pre {
  background:var(--pre-bg); color:var(--pre-fg); padding:1rem 1.1rem;
  border-radius:8px; overflow-x:auto; font-size:.83rem; line-height:1.55;
  box-shadow:var(--shadow);
}
pre code { background:none; color:inherit; padding:0; font-size:1em; }
blockquote {
  margin:1.2rem 0; padding:.85rem 1.1rem; background:var(--accent-soft);
  border-left:3px solid var(--accent); border-radius:0 6px 6px 0;
}
blockquote p:first-child { margin-top:0; } blockquote p:last-child { margin-bottom:0; }
.table-wrap { overflow-x:auto; margin:1.2rem 0; }
table { border-collapse:collapse; width:100%; font-size:.88rem; background:var(--card);
  border:1px solid var(--rule); border-radius:8px; }
th,td { text-align:left; padding:.55rem .8rem; border-bottom:1px solid var(--rule); vertical-align:top; }
th { font-weight:650; font-size:.76rem; text-transform:uppercase; letter-spacing:.05em;
  color:var(--muted); background:var(--code-bg); }
tbody tr:last-child td { border-bottom:none; }
ul,ol { margin:.85rem 0; padding-left:1.4rem; }
li { margin:.35rem 0; }
li > ul, li > ol { margin:.35rem 0; }
hr { border:none; border-top:1px solid var(--rule); margin:2.5rem 0; }
@media (max-width:900px) {
  .layout { grid-template-columns:1fr; }
  nav { position:static; max-height:none; border-right:none;
        border-bottom:1px solid var(--rule); padding:1.5rem 1.25rem; }
  main { padding:1.75rem 1.25rem 4rem; }
}
@media print {
  nav { display:none; } .layout { display:block; } main { padding:0; }
  pre { background:#f4f4f4; color:#000; border:1px solid #ccc; }
  a { color:#000; }
}
"""

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>{css}</style>
</head>
<body>
<div class="layout">
<nav><div class="toc-title">Contents</div>
{toc}
</nav>
<main>
{body}
</main>
</div>
</body>
</html>
"""


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]

    lines = open(src, encoding="utf-8").read().replace("\t", "    ").split("\n")
    body, toc = Renderer(lines).run()

    title = next((l[2:].strip() for l in lines if l.startswith("# ")), src)
    toc_html = "\n".join(
        '<a class="lvl%d" href="#%s">%s</a>' % (lvl, anchor, html.escape(text))
        for lvl, text, anchor in toc
    )

    open(dst, "w", encoding="utf-8").write(
        PAGE.format(title=html.escape(title), css=CSS, toc=toc_html, body=body)
    )
    print("%s -> %s" % (src, dst))


main()
