#!/usr/bin/env bash
# ui_sizes_test.sh: static guard for the UI scale of our custom QML (src/quickshell/custom/, vpn/ excluded until it is migrated).
# Rules:
#   1. every font-size assignment (pixelSize / *FontSize / *PixelSize) must go through XUi (XUi.fBody, XUi.font(n), XUi.cmdFont(n) ...)
#      so the type follows the stock scale; a bare number or Scaler.s(N) bypasses it, unless the line is in ALLOW below;
#   2. a number inside such an assignment (XUi.s(N), XUi.font(N)) must not be below the minimum body size (XUi.fCaption = 11);
#   3. cmd/ (the 1600x860 design canvas, shown with scale XUi.cmdZoom) may use design sizes >= XUi.cmdMinFont (10): CT `size: N` literals are checked
#      against that, and cmd pixelSize goes through XUi.cmdFont();
#   4. XUi.qml itself must keep the stock values (caption 11, body 12, row 13, title 16, icon box 32, row 32).
# ALLOW: "<file basename>|<substring of the line>|<reason>"
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
base = os.path.join(root, "src/quickshell/custom")
ALLOW = [
    # (file basename, substring, reason)
]
MIN_BODY = 11
CMD_MIN = 10
prop = re.compile(r'\b(\w*(?:[Ff]ontSize|PixelSize|pixelSize|[Ff]ontPixel\w*))\s*:\s*(.*)$')
nums = re.compile(r'(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])')
bad = 0; n = 0
def fail(p, i, msg, line):
    global bad
    bad += 1
    print(f"FAIL {os.path.relpath(p, root)}:{i}: {msg}: {line.strip()[:110]}")
for d, _, files in os.walk(base):
    rel = os.path.relpath(d, base)
    if rel == "vpn" or rel.startswith("vpn/"): continue
    for f in sorted(files):
        if not f.endswith(".qml") or f == "XUi.qml": continue
        p = os.path.join(d, f)
        incmd = rel == "cmd"
        for i, line in enumerate(open(p, encoding="utf-8"), 1):
            code = line.split("//")[0]
            if any(a[0] == f and a[1] in line for a in ALLOW): continue
            for m in prop.finditer(code):
                n += 1
                rhs = m.group(2)
                if m.group(1) == "pixelSize" and rhs.strip().startswith("parent.font"): pass
                if "XUi." not in rhs:
                    fail(p, i, "font size bypasses XUi", line); continue
                call = re.findall(r'XUi\.(?:s|font)\(([^()]*)\)', rhs)
                for arg in call:
                    for v in nums.findall(arg):
                        if float(v) < MIN_BODY and not incmd:
                            fail(p, i, f"size {v} below the {MIN_BODY}px minimum", line)
                if incmd and "XUi.cmdFont" not in rhs and "XUi.f" not in rhs and "XUi.icon" not in rhs:
                    fail(p, i, "cmd font must use XUi.cmdFont()", line)
            if incmd:
                for m in re.finditer(r'\bCT\s*\{[^}]*?\bsize:\s*(\d+)', code):
                    n += 1
                    if int(m.group(1)) < CMD_MIN: fail(p, i, f"CT size {m.group(1)} below design minimum {CMD_MIN}", line)
                m = re.match(r'\s*size:\s*(\d+)\b', code)
                if m and f != "CT.qml":
                    n += 1
                    if int(m.group(1)) < CMD_MIN and "CT" in "".join(open(p, encoding="utf-8").read().split("\n")[max(0, i-3):i]):
                        fail(p, i, f"size {m.group(1)} below design minimum {CMD_MIN}", line)
# XUi keeps the stock values
x = open(os.path.join(base, "XUi.qml"), encoding="utf-8").read()
for name, val in (("fCaption", 11), ("fBody", 12), ("fRow", 13), ("fTitle", 16), ("iconBox", 32), ("rowH", 32), ("btnH", 30), ("tabH", 44)):
    m = re.search(r'property real %s:\s*s\((\d+)\)' % name, x)
    n += 1
    if not m or int(m.group(1)) != val:
        bad += 1; print(f"FAIL XUi.qml: {name} must be s({val}) (stock value)")
for name in ("fCaption", "fBody", "fRow", "fSub", "fTitle", "fHead", "fHero"):
    m = re.search(r'property real %s:\s*s\((\d+)\)' % name, x)
    if m and int(m.group(1)) < MIN_BODY:
        bad += 1; print(f"FAIL XUi.qml: {name} below minimum")
print(f"ui_sizes_test: {n} size declarations checked, {bad} failed")
sys.exit(1 if bad else 0)
PY
