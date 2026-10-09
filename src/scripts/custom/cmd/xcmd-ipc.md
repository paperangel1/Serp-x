# `xcmd`: IPC target of the shell for the commands engine

Since stage 9a the QML side exists: `src/quickshell/custom/cmd/XCmdShell.qml`, exposed by the `xcmd` IpcHandler of `XCmdHost.qml`
(instantiated from `XTools`). The engine calls it only through `executors/shellapi.py` (`serpantinum ipc call xcmd <fn> [arg]`;
`XCMD_SERPANTINUM_BIN` overrides the binary in tests). **No upstream file is edited.**
Functions print one line to stdout and exit 0; a printed value starting with `err:` is an error text for the user.

| function | argument | prints | how it works |
|---|---|---|---|
| `getDnd` / `setDnd` | – / `true`/`false` | `true`/`false` / – | writes the same Config flag `notifications.dnd` as the notification-panel button. Upstream `NotificationPopups` and `Notification.qml` already honour it: popups and sound are muted, **critical (urgency 2) notifications still show**, all notifications stay in the notification centre. |
| `getTheme` / `setTheme` | – / `dark`\|`light`\|`toggle`, optional `:scheme-<name>` | `dark[:scheme-x]` / `ok` | sets Config `theme.mode` (+ `theme.schemeType`) and regenerates Matugen from the current wallpaper (`Wallpaper.getWallpaperPath("")`). With a fixed (non-Matugen) palette only the mode is saved. |
| `getNightFilter` / `setNightFilter` | – / `on`\|`off`, optional `:<temp>` | `on:4000` / `ok` | `BlueLight.setTemperature` + `BlueLight.setEnabled` (kelvin 1000-10000 or the 0-100 settings scale). |
| `getBar` / `setBar` | – / `show`\|`hide`\|`toggle` | `shown`\|`hidden` / `ok` | the Config flag `bar.autohide` (same switch as `main` IPC «autohide»): `hidden` = the bar slides away and returns when the pointer touches its edge. |

Wallpaper uses the existing upstream target (`ipc call wallpaper setWallpaper all <path> fade`, `getWallpaperPath ""`); brightness uses
`serpantinum brightness get|set N`; volume/microphone use `wpctl`, sink switching `pactl`, media `playerctl`, windows `hyprctl`.

Limits: theme/night-filter changes need the shell running with this version (otherwise «Цель «xcmd» оболочки не отвечает»);
a theme change takes a second or two (matugen); the video wallpaper's captured path may be its poster, not the video.

Undo: the engine captures with `getX` before `setX` and restores the printed value when the run ends, fails or is cancelled
(property `restore: end`).

## Daemon → shell requests (`ui.request`, stage 5)

The shell (`custom/cmd/XCmdBridge.qml`) keeps a connection to the daemon socket, calls `subscribe {"topics": ["ui"]}` and answers
every request with the `ui_response` method (`params.id` = request id). Without a connected shell the engine falls back
(show → notification, ask → «Время вышло» path, confirm → run cancelled).

| kind | payload | answer |
|---|---|---|
| `show` | `{title, text}` | `{shown: true}` (answered at once; the popup stays on screen) |
| `confirm` | `{node, text}` | `{answer: bool}` |
| `ask` | `{mode: choice\|text\|number\|confirm, title, options, default, timeout, command, run}` | `{index}` (choice), `{value}` (text, number), `{answer}` (confirm), or `{cancel: true}` |

`{"ev": "ui.cancel", "id": ...}` is pushed when a request timed out or its run was cancelled: the shell must close that dialog.

## `xvpn` (stage 9c: `action.vpn.set`, `executors` via `xcmd/vpnapi.py`)

The daemon lives in the user systemd manager (no logind session), where polkit refuses `systemctl start serp-xray`
(`start_failed`). So the engine never starts the tunnel itself: it asks the shell, which runs inside the session
(`custom/vpn/XVpnHost.qml` -> `XVpn` -> `x_vpn.sh`). One printed line each, `err:<ru text>` = error for the user. The calls only START
the work and return; the engine polls `status` (1 s step, 30 s to come up, 12 s to go down).

| function | argument | prints |
|---|---|---|
| `connect` | node name or id, empty = selected node | `ok` / `err:…` (refuses while Happ is active; switches the node when already on) |
| `disconnect` | – | `ok` |
| `switchTo` | node name or id | `ok` / `err:…` (needs a running tunnel; ambiguous names are refused) |
| `status` | – | `{"state":"on\|off\|starting\|switching\|failed\|unknown","node":"…","reason":"…","happ":false}` |

Happ's VPN is never stopped, by anything here. Undo of `action.vpn.set` restores the previous on/off (and node) best effort and is
skipped quietly when Happ appeared meanwhile. Logs carry states and results only (`serpantinum-x logs cmd`), never node names.

`event.vpn.changed` is fed by the VPN module's own event log (`events.jsonl`, `vpn.connected|disconnected|failed|node_changed`),
read-only, from the end of the file.
