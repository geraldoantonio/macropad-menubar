#!/usr/bin/env python3
"""Checks that every text passed to L(...) has an English and a Spanish translation.

Run from the repo root: python3 scripts/check-l10n.py  (exit 1 on missing/unused keys).
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
sources = {p: p.read_text() for p in (root / "Sources").rglob("*.swift") if p.name != "L10nStrings.swift"}

def swift_unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")

keys = set()
for text in sources.values():
    for m in re.finditer(r'\bL\(\s*"((?:[^"\\]|\\.)*)"', text):
        keys.add(swift_unescape(m.group(1)))

# Keys used indirectly (tables whose values are passed to L).
def dict_values(path, name):
    text = (root / path).read_text()
    block = re.search(name + r'[^=]*=\s*\[(.*?)\]', text, re.S).group(1)
    return {v for v in re.findall(r':\s*"((?:[^"\\]|\\.)*)"', block)}

def array_values(path, name):
    text = (root / path).read_text()
    block = re.search(name + r'\s*=\s*\[(.*?)\]', text, re.S).group(1)
    return set(re.findall(r'"((?:[^"\\]|\\.)*)"', block))

keys |= dict_values("Sources/MacropadCore/Display.swift", "mediaLabels")
keys |= dict_values("Sources/MacropadCore/Display.swift", "mouseLabels")
keys |= dict_values("Sources/MacropadCore/Display.swift", "mediaTitleKeys")
keys |= dict_values("Sources/MacropadCore/Display.swift", "mouseTitleKeys")
keys |= array_values("Sources/MacropadMenuBar/PadModel.swift", "ledTitles")
editor = (root / "Sources/MacropadMenuBar/SlotEditor.swift").read_text()
kind = re.search(r'enum Kind[^{]*\{(.*?)\n        var', editor, re.S).group(1)
keys |= set(re.findall(r'\w+ = "([^"]+)"', kind))
presets = (root / "Sources/MacropadCore/Presets.swift").read_text()
keys |= set(re.findall(r'Preset\(name: "([^"]+)"', presets))

# Visible text passed straight to SwiftUI, or as the branch of a ?: inside one, without L(...).
ui_call = re.compile(r'\b(Text|Button|Label|Toggle|Picker|Menu|Section|TextField|help|accessibilityLabel)\(\s*"([^"]*[a-zà-ú]{3,}[^"]*)"')
ternary = re.compile(r'^\s*[:?] "([^"]*[a-zà-ú]{3,}[^"]*)"')
allowed = {"Macropad", "Presets", "LED"}
ok = True
for path, text in sources.items():
    if "MacropadMenuBar" not in str(path): continue
    for n, line in enumerate(text.splitlines(), 1):
        for m in ui_call.finditer(line):
            if m.group(2) not in allowed and not m.group(2).startswith("\\("):
                print(f"{path.name}:{n}: texto sem L(): {m.group(2)!r}"); ok = False
        m = ternary.match(line)
        if m:
            print(f"{path.name}:{n}: texto sem L(): {m.group(1)!r}"); ok = False

strings = (root / "Sources/MacropadCore/L10nStrings.swift").read_text()
for lang in ("en", "es"):
    block = re.search(r'static let ' + lang + r': \[String: String\] = \[(.*?)\n    \]', strings, re.S).group(1)
    pairs = re.findall(r'^\s*"((?:[^"\\]|\\.)*)":\s*"((?:[^"\\]|\\.)*)",?\s*$', block, re.M)
    table = {swift_unescape(k): swift_unescape(v) for k, v in pairs}
    if len(table) != len(pairs):
        print(f"[{lang}] chave duplicada (o app quebraria ao abrir)"); ok = False
    missing = sorted(keys - table.keys())
    unused = sorted(table.keys() - keys)
    for k in missing: print(f"[{lang}] falta: {k!r}"); ok = False
    for k in unused: print(f"[{lang}] sem uso: {k!r}"); ok = False
    for k, v in table.items():
        if k.count("%@") != v.count("%@"):
            print(f"[{lang}] %@ diferente: {k!r} -> {v!r}"); ok = False
print(f"{len(keys)} textos; " + ("ok" if ok else "com problemas"))
sys.exit(0 if ok else 1)
