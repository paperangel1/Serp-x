#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# editor_logic_test.sh: tests of src/quickshell/custom/cmd/EditorLogic.js with plain `qml6` (no Quickshell, no desktop).
# data.js is generated from the REAL CLI (ui-schema + ui-get of the fixture commands), so the parity part compares the JS
# view builder with uiview.py field by field. Offline, temp dirs only.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$DIR/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
command -v qml6 >/dev/null 2>&1 || { echo "qml6 not installed: skipped"; exit 0; }
export PYTHONDONTWRITEBYTECODE=1
python3 "$DIR/cmd_ui/make_fixtures.py" "$T/fx" --big 40 >/dev/null || exit 1
export XCMD_COMMANDS_DIR="$T/fx/commands" XCMD_EXTRA_NODES="$T/fx/nodes" XCMD_STATE_DIR="$T/state" XCMD_SOCKET="$T/none.sock" HOME="$T"
X="$SRC/scripts/custom/cmd/x_cmd.sh"
python3 - "$X" "$T" <<'PY' || exit 1
import json, os, subprocess, sys
x, t = sys.argv[1], sys.argv[2]
schema = json.loads(subprocess.check_output(["bash", x, "ui-schema"]))
gets = {}
for f in sorted(x for x in os.listdir(os.path.join(t, "fx", "commands")) if x.endswith(".cmd.json")):
    g = json.loads(subprocess.check_output(["bash", x, "ui-get", os.path.join(t, "fx", "commands", f)]))
    gets[f[:-len(".cmd.json")]] = {k: g[k] for k in ("command", "nodes", "wires", "comments", "bounds")}
gal = os.path.join(os.path.dirname(x), "..", "..", "..", "assets", "custom-commands", "gallery", "focus-25.cmd.json")
g = json.loads(subprocess.check_output(["bash", x, "ui-get", gal]))      # a gallery command: {ru, en} comments
gets["gallery-focus-25"] = {k: g[k] for k in ("command", "nodes", "wires", "comments", "bounds")}
tutorial = json.loads(subprocess.check_output(["bash", x, "tutorial", "get"]))
traces = {}      # real engine rehearsals (local mode, no daemon): the debug overlay reducer is tested on them
for name in [n for n in gets if not n.startswith("gallery-")]:
    try:
        res = json.loads(subprocess.check_output(["bash", x, "--json", "run", gets[name]["command"]["name"], "--rehearse"], stderr=subprocess.DEVNULL))
        traces[name] = json.loads(subprocess.check_output(["bash", x, "--json", "trace", res["run"]], stderr=subprocess.DEVNULL))
    except subprocess.CalledProcessError:
        pass
with open(os.path.join(t, "data.js"), "w", encoding="utf-8") as fh:
    fh.write(".pragma library\nvar schema = " + json.dumps({"catalog": schema["catalog"]}, ensure_ascii=False) + ";\nvar gets = " + json.dumps(gets, ensure_ascii=False) + ";\nvar traces = " + json.dumps(traces, ensure_ascii=False) + ";\nvar tutorial = " + json.dumps(tutorial, ensure_ascii=False) + ";\n")
PY
cp "$SRC/quickshell/custom/cmd/EditorLogic.js" "$SRC/quickshell/custom/cmd/DebugLogic.js" "$DIR/cmd_ui/editor_logic_test.qml" "$T/"
cd "$T" && QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen timeout 120 qml6 editor_logic_test.qml 2>&1 | grep -v -E "^QStandardPaths|qt.qpa|propagateSizeHints" | tail -40
exit "${PIPESTATUS[0]}"
