#!/usr/bin/env python3
"""Every translatable English string of the app (the page's L() and EN_TEXT, Swift's L(), the engine descriptions)
against the ten language packs ui/i18n/<code>.js: what a pack is missing, what it holds that the code no longer
writes, and placeholders that don't match. Exit 1 if a pack misses a string or a placeholder.

Key = the English text with each interpolation (${…} in the page, \\(…) in Swift) replaced by {0}, {1}, … in order.
Usage: python3 tools/i18n_check.py [--dump source.json]   (from the repo root)
"""
import json, re, sys, pathlib

repo = pathlib.Path(__file__).resolve().parent.parent

# ---------- a small literal parser shared by JS and Swift ----------
def skip_ws(s, i):
    while i < len(s):
        if s[i].isspace(): i += 1
        elif s.startswith("//", i): i = s.index("\n", i)
        elif s.startswith("/*", i): i = s.index("*/", i) + 2
        else: break
    return i

def js_literal(s, i):
    """Parse a JS string literal at s[i]; return (text_with_placeholders, exprs, end) or None."""
    q = s[i]
    if q not in "'\"`": return None
    i += 1; buf = []; exprs = []
    while i < len(s):
        c = s[i]
        if c == "\\":
            n = s[i + 1]
            buf.append({"n": "\n", "t": "\t", "u": None}.get(n, n) if n != "u" else chr(int(s[i + 2:i + 6], 16)))
            i += 6 if n == "u" else 2; continue
        if c == q: return "".join(buf), exprs, i + 1
        if q == "`" and s.startswith("${", i):
            j = i + 2; depth = 1
            while depth:
                ch = s[j]
                if ch in "'\"`":
                    r = js_literal(s, j); j = r[2]; continue
                if ch == "{": depth += 1
                elif ch == "}": depth -= 1
                j += 1
            buf.append("{%d}" % len(exprs)); exprs.append(s[i + 2:j - 1]); i = j; continue
        buf.append(c); i += 1
    raise ValueError("unterminated literal at %d" % i)

def swift_literal(s, i):
    if s[i] != '"' or s.startswith('"""', i): return None
    i += 1; buf = []; exprs = []
    while i < len(s):
        c = s[i]
        if c == "\\":
            n = s[i + 1]
            if n == "(":
                j = i + 2; depth = 1
                while depth:
                    ch = s[j]
                    if ch == '"':
                        r = swift_literal(s, j); j = r[2]; continue
                    if ch == "(": depth += 1
                    elif ch == ")": depth -= 1
                    j += 1
                buf.append("{%d}" % len(exprs)); exprs.append(s[i + 2:j - 1]); i = j; continue
            if n == "u":                                  # \u{00A0}
                k = s.index("}", i); buf.append(chr(int(s[i + 3:k], 16))); i = k + 1; continue
            buf.append({"n": "\n", "t": "\t"}.get(n, n)); i += 2; continue
        if c == '"': return "".join(buf), exprs, i + 1
        buf.append(c); i += 1
    raise ValueError("unterminated")

def calls(src, lit, name="L", lang="js"):
    """Every name(lit, lit) call; non-literal arguments are reported."""
    found, odd = [], []
    for m in re.finditer(r"(?<![\w.$])" + name + r"\(", src):
        i = skip_ws(src, m.end())
        a = lit(src, i)
        line = src.count("\n", 0, m.start()) + 1
        if not a: odd.append((line, src[m.start():m.start() + 120])); continue
        j = skip_ws(src, a[2])
        if src[j] != ",": odd.append((line, src[m.start():m.start() + 120])); continue
        j = skip_ws(src, j + 1)
        b = lit(src, j)
        if not b: odd.append((line, src[m.start():m.start() + 160])); continue
        k = skip_ws(src, b[2])
        if src[k] != ")": odd.append((line, src[m.start():m.start() + 160])); continue
        found.append({"ko": a[0], "en": b[0], "ko_args": a[1], "en_args": b[1], "line": line})
    return found, odd

entries = {}      # key -> entry
def add(key, ko, where, note=""):
    if not re.search(r"[A-Za-z]", re.sub(r"\{\d+\}", "", key)): return     # nothing to translate
    e = entries.setdefault(key, {"en": key, "ko": ko, "where": [], "note": note})
    if where not in e["where"]: e["where"].append(where)
    if note and not e["note"]: e["note"] = note

page = (repo / "ui/index.html").read_text()
script_start = page.index("<script>")
found, odd = calls(page[script_start:], js_literal)
base_line = page.count("\n", 0, script_start)
for f in found: add(f["en"], f["ko"], "page:%d" % (f["line"] + base_line), "args: " + " | ".join(f["en_args"]) if f["en_args"] else "")
odd_all = [("page", l + base_line, t) for l, t in odd]

# EN_TEXT table (Korean markup text → English)
m = re.search(r"const EN_TEXT = \{(.*?)\n  \};", page, re.S)
for k, v in re.findall(r'^\s*"((?:[^"\\]|\\.)*)":\s*"((?:[^"\\]|\\.)*)",?\s*$', m.group(1), re.M):
    add(json.loads('"%s"' % v), json.loads('"%s"' % k), "page:markup")

for p in sorted((repo / "app").rglob("*.swift")):
    src = p.read_text()
    f2, o2 = calls(src, swift_literal, lang="swift")
    for f in f2: add(f["en"], f["ko"], "%s:%d" % (p.relative_to(repo), f["line"]), "args: " + " | ".join(f["en_args"]) if f["en_args"] else "")
    odd_all += [(str(p.relative_to(repo)), l, t) for l, t in o2]

# engine descriptions (EngineSpec descKo/descEn, chosen when read)
w = (repo / "app/Whisper.swift").read_text()
for ko, en in re.findall(r'descKo: "((?:[^"\\]|\\.)*)", descEn: "((?:[^"\\]|\\.)*)"', w):
    add(en, ko, "app/Whisper.swift:engineSpecs")
# words the code passes into a sentence (translated when they fill a {0}) and Finder's folder names
for en, ko, note in [("English", "English", "the lecture-language switch's second button / filled into a sentence"),
                     ("Korean", "한국어", "a lecture language, filled into a sentence"),
                     ("Downloads", "다운로드", "macOS Finder folder name — use Finder's own localized name"),
                     ("Documents", "문서", "macOS Finder folder name — use Finder's own localized name"),
                     ("Desktop", "데스크탑", "macOS Finder folder name — use Finder's own localized name")]:
    add(en, ko, "extra", note)

plist = {}
for p in [repo / "app/Resources/en.lproj/InfoPlist.strings", repo / "app/ios/en.lproj/InfoPlist.strings"]:
    for k, v in re.findall(r'^"(\w+)" = "((?:[^"\\]|\\.)*)";', p.read_text(), re.M):
        plist.setdefault(k, [])
        if v not in plist[k]: plist[k].append(v)


bad = 0
for p in sorted((repo / "ui/i18n").glob("*.js")):
    js = p.read_text()
    lang = p.stem
    head = f'(window.I18N = window.I18N || {{}})["{lang}"] = '
    pack = json.loads(js[js.index(head) + len(head):js.rindex("}") + 1])
    text = pack["text"]
    missing = [k for k in entries if k not in text]
    stale = [k for k in text if k not in entries]
    ph = lambda s: sorted(re.findall(r"\{\d+\}", s))
    wrong = [k for k in entries if k in text and ph(k) != ph(text[k])]
    print(f"{lang}: {len(text)} strings · missing {len(missing)} · stale {len(stale)} · placeholder mismatches {len(wrong)}")
    for k in missing: print("   missing:", k[:110].replace("\n", "⏎"), "—", entries[k]["where"][0])
    for k in wrong: print("   placeholders:", k[:110])
    for k in stale: print("   stale (unused):", k[:110])
    bad += bool(missing or wrong)
if "--dump" in sys.argv:
    pathlib.Path(sys.argv[sys.argv.index("--dump") + 1]).write_text(json.dumps({"strings": list(entries.values()), "infoplist": plist}, ensure_ascii=False, indent=1))
print("non-literal L() calls (not checked):", len(odd_all))
sys.exit(1 if bad else 0)
