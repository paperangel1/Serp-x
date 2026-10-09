#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# Every directory imported by our QML (import "../x") must have a qmldir: in Quickshell's qs:@ virtual
# filesystem a bare directory exposes no types, which only fails in the live shell, not in offscreen tests.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
base = os.path.join(root, "src/quickshell/custom")
bad = 0; n = 0
for d, _, files in os.walk(base):
    for f in files:
        if not f.endswith(".qml"): continue
        p = os.path.join(d, f)
        for i, line in enumerate(open(p, encoding="utf-8"), 1):
            m = re.match(r'\s*import\s+"([^"]+)"', line)
            if not m: continue
            if m.group(1).endswith('.js'): continue   # JS module import, not a directory
            n += 1
            tgt = os.path.normpath(os.path.join(d, m.group(1)))
            if tgt == os.path.normpath(d): continue
            if not os.path.isfile(os.path.join(tgt, "qmldir")):
                bad += 1
                print(f"FAIL {os.path.relpath(p, root)}:{i}: import \"{m.group(1)}\" -> no qmldir in {os.path.relpath(tgt, root)}")
# Second check: every custom component/singleton a file uses must be visible through the qmldirs it can
# actually see in the qs:@ VFS: its own directory's qmldir (siblings) plus the qmldir of each imported
# directory. Offscreen tests on a plain filesystem resolve siblings implicitly; the live shell does not.
def parse_qmldir(path):
    names = set()
    if not os.path.isfile(path): return names
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"): continue
        parts = line.split()
        if parts[0] == "singleton": parts = parts[1:]
        if parts: names.add(parts[0])
    return names
all_names = set()
for d, _, files in os.walk(base):
    if "qmldir" in files: all_names |= parse_qmldir(os.path.join(d, "qmldir"))
for extra in ("qmldir", "reusables/qmldir"):
    all_names |= parse_qmldir(os.path.join(root, "src/quickshell", extra))
bad2 = 0; m2 = 0
for d, _, files in os.walk(base):
    for f in files:
        if not f.endswith(".qml"): continue
        p = os.path.join(d, f); own = f[:-4]
        src = open(p, encoding="utf-8").read()
        imp_code = "\n".join(l.split("//")[0] for l in src.split("\n"))
        code = imp_code
        code = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', code)   # string literals (file names etc.) are not type uses
        visible = parse_qmldir(os.path.join(d, "qmldir"))
        for mm in re.finditer(r'^\s*import\s+"([^"]+)"', imp_code, re.M):
            tgt = os.path.normpath(os.path.join(d, mm.group(1)))
            visible |= parse_qmldir(os.path.join(tgt, "qmldir"))
        for name in sorted(all_names):
            if name == own: continue
            if re.search(r'(?<![\w."])' + re.escape(name) + r'\s*\{|(?<![\w."])' + re.escape(name) + r'\.\w', code):
                m2 += 1
                if name not in visible:
                    bad2 += 1
                    print(f"FAIL {os.path.relpath(p, root)}: uses {name} but no imported/own qmldir exposes it")
print(f"qml_imports_test: {n} imports checked, {bad} failed; {m2} type references checked, {bad2} unresolved")
sys.exit(1 if (bad or bad2) else 0)
PY
