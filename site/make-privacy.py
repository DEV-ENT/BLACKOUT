#!/usr/bin/env python3
"""Writes site/privacy.html from PRIVACY.md, so the page always says the same as the policy in the repo.

Run from the repo root after changing PRIVACY.md:  python3 site/make-privacy.py
Handles what PRIVACY.md uses: # and ## headings, paragraphs, "- " lists (one level of nesting), **bold**, and the
support e-mail address, which becomes a link.
"""
import html
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
md = (ROOT / "PRIVACY.md").read_text(encoding="utf-8")


def inline(text):
    t = html.escape(text, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"\b([\w.+-]+@darkproof\.app)\b", r'<a href="mailto:\1">\1</a>', t)
    return t


out, para, depth = [], [], 0


def flush():
    global para
    if para:
        out.append("<p>" + inline(" ".join(para)) + "</p>")
        para = []


def close_lists(to):
    global depth
    while depth > to:
        out.append("</li></ul>")
        depth -= 1


for line in md.splitlines():
    m = re.match(r"^( *)- (.*)$", line)
    if line.startswith("#"):
        flush(); close_lists(0)
        level = len(line) - len(line.lstrip("#"))
        text = line[level:].strip()
        out.append(f"<h{level}>{inline(text)}</h{level}>")
    elif m:
        flush()
        level = len(m.group(1)) // 2 + 1
        if level > depth:
            while depth < level:
                out.append("<ul><li>")
                depth += 1
        else:
            close_lists(level)
            out.append("</li><li>")
        out.append(inline(m.group(2)))
    elif not line.strip():
        flush(); close_lists(0)
    else:
        if depth:
            out.append(" " + inline(line.strip()))
        else:
            para.append(line.strip())
flush(); close_lists(0)

body = "\n".join(out)
page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer">
<title>DarkProof privacy policy</title>
<meta name="description" content="What DarkProof keeps on your phone, what it sends, and to whom.">
<link rel="icon" href="favicon.png" type="image/png">
<link rel="stylesheet" href="style.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<div class="wrap">
<header class="site">
  <img src="logo.png" alt="" width="40" height="40">
  <a href="./">DarkProof</a>
</header>
<!-- Generated from PRIVACY.md by site/make-privacy.py. Edit PRIVACY.md, not this file. -->
<main id="main">
{body}
</main>
<footer class="site">
  <nav aria-label="Footer">
    <a href="./">About DarkProof</a>
    <a href="mailto:support@darkproof.app">support@darkproof.app</a>
  </nav>
</footer>
</div>
</body>
</html>
"""
(ROOT / "site" / "privacy.html").write_text(page, encoding="utf-8")
print("wrote site/privacy.html")
