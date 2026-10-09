<!-- This file is generated from the node schema; do not edit it by hand. -->

## Events

### App closed (`event.app_closed@1`)

Starts the command when an application window closes. Class and title come from the window's last known state.

- Kind: event (starts the command)
- Capabilities: `trigger.windows`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `class_filter` | input | text | Window class |  |
| `title_filter` | input | text | Title contains |  |
| `exec` | output | execution | Start |  |
| `class` | output | text | Window class |  |
| `title` | output | text | Title |  |

**Example:** Steam closed → restore audio.

### App opened (`event.app_opened@1`)

Starts the command when an application window opens. Class and title filters are optional (case-insensitive substring; a leading «re:» means a regular expression).

- Kind: event (starts the command)
- Capabilities: `trigger.windows`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `class_filter` | input | text | Window class |  |
| `title_filter` | input | text | Title contains |  |
| `exec` | output | execution | Start |  |
| `class` | output | text | Window class |  |
| `title` | output | text | Title |  |
| `workspace` | output | text | Workspace |  |

**Example:** Steam opened → switch audio to the speakers.

### Headphones connected (`event.audio.headphones_connected@1`)

Fires when headphones are connected: Bluetooth (a BlueZ audio device in PipeWire) or wired (jack). The source watches sound device changes (pactl subscribe) and waits a second for things to settle. Read-only.

- Kind: event (starts the command)
- Capabilities: `trigger.audio`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `kind_filter` | input | text | Kind | any |
| `exec` | output | execution | Start |  |
| `name` | output | text | Name |  |
| `kind` | output | text | Kind (bluetooth or wired) |  |

**Example:** Headphones connected → volume 40%.

### Headphones disconnected (`event.audio.headphones_disconnected@1`)

Fires when headphones are disconnected (Bluetooth or wired). The name and kind are those of the headphones that went away.

- Kind: event (starts the command)
- Capabilities: `trigger.audio`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `kind_filter` | input | text | Kind | any |
| `exec` | output | execution | Start |  |
| `name` | output | text | Name |  |
| `kind` | output | text | Kind (bluetooth or wired) |  |

**Example:** Headphones disconnected → pause.

### Bluetooth device (`event.bluetooth.device@1`)

Fires when a Bluetooth device connects or disconnects (headphones, keyboard, mouse...). It can be limited by name or MAC address (part of the text or re:regex) and by the event. The source is BlueZ over D-Bus (dbus-monitor), read-only: nothing is connected or scanned.

- Kind: event (starts the command)
- Capabilities: `trigger.bluetooth`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `name_filter` | input | text | Name or MAC |  |
| `change` | input | text | Event | connected |
| `exec` | output | execution | Start |  |
| `name` | output | text | Name |  |
| `kind` | output | text | Kind (audio, input, other) |  |
| `connected` | output | yes/no | Connected | False |

**Example:** Headphones connected → start music.

### Colour copied (`event.clipboard.color@1`)

Fires when a colour is copied: "#rgb", "#rrggbb", "rgb(12, 34, 56)" or "hsl(200, 50%, 40%)" (the whole clipboard is just the colour). Gives the colour as HEX and RGB. This is the SAME separate "watch the clipboard" right as "Link copied": the shell reads the clipboard while the command is enabled. Only this command gets the content and it is never stored; only the kind and the length are logged. Copies made by a command ("Put in clipboard") are ignored.

- Kind: event (starts the command)
- Capabilities: `trigger.clipboard`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec` | output | execution | Start |  |
| `hex` | output | text | HEX |  |
| `rgb` | output | text | RGB |  |

**Example:** Copied "#3b82f6" → show HEX and RGB.

### Link copied (`event.clipboard.link@1`)

Fires when a link is copied to the clipboard (the whole clipboard is a single http or https address). It can be limited to sites ("youtube.com, youtu.be", subdomains match) and by a regular expression on the address. This is a SEPARATE right: the shell reads the clipboard while the command is enabled. The link goes only to this command and is never stored; only the domain and the length are logged. Copies made by a command ("Put in clipboard") are ignored.

- Kind: event (starts the command)
- Capabilities: `trigger.clipboard`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `domains` | input | text | Sites |  |
| `regex` | input | text | Regular expression |  |
| `exec` | output | execution | Start |  |
| `url` | output | text | Link |  |
| `domain` | output | text | Domain |  |

**Example:** A YouTube link was copied → offer to download it.

### Phone number copied (`event.clipboard.phone@1`)

Fires when a phone number is copied (the whole clipboard is 7-15 digits, optionally with "+", spaces, brackets and dashes; dates and IP addresses do not count). Gives the digits and an E.164-like number ("+7…" for Russian 8… and 10-digit numbers). This is the SAME separate "watch the clipboard" right as "Link copied": the shell reads the clipboard while the command is enabled. Only this command gets the content and it is never stored; only the kind and the length are logged. Copies made by a command ("Put in clipboard") are ignored.

- Kind: event (starts the command)
- Capabilities: `trigger.clipboard`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec` | output | execution | Start |  |
| `digits` | output | text | Digits |  |
| `e164` | output | text | Number (E.164) |  |

**Example:** Copied a number → offer to call or save it.

### New file in a folder (`event.folder.new_file@1`)

Fires when a new file appears in a folder. Partial downloads (.part, .crdownload, .tmp, hidden files) are skipped and a file counts as ready when its size has not changed for 3 seconds. Filter: patterns or extensions ("pdf png", "*.jpg"). The folder is watched with inotify; file contents are not read.

- Kind: event (starts the command)
- Capabilities: `trigger.folder`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `folder` | input | text | Folder | ~/Downloads |
| `pattern` | input | text | Pattern or extension |  |
| `recursive` | input | yes/no | Subfolders | False |
| `exec` | output | execution | Start |  |
| `path` | output | text | Path |  |
| `name` | output | text | File name |  |
| `kind` | output | text | Kind (image, document, archive, video, audio, other) |  |

**Example:** New file in Downloads → sort it into folders.

### Idle (`event.idle@1`)

Starts the command when the mouse and keyboard have been untouched for the given number of minutes.

- Kind: event (starts the command)
- Capabilities: `trigger.session`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `minutes` | input | number | Minutes | 10 |
| `exec` | output | execution | Start |  |

**Example:** 10 minutes idle → pause the music.

### Back from idle (`event.idle_return@1`)

Starts the command when you return after being idle for the given number of minutes.

- Kind: event (starts the command)
- Capabilities: `trigger.session`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `minutes` | input | number | Minutes | 10 |
| `exec` | output | execution | Start |  |

**Example:** Back after 10 minutes → resume the music.

### Every N minutes (`event.interval@1`)

Starts the command regularly every given number of minutes while the automation is enabled.

- Kind: event (starts the command)
- Capabilities: `trigger.time`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `minutes` | input | number | Minutes | 30 |
| `exec` | output | execution | Start |  |
| `time` | output | time | Time | 00:00 |

**Example:** Every 30 minutes → stretch reminder.

### Screen locked (`event.lock@1`)

Starts the command when the session is locked (systemd-logind signal).

- Kind: event (starts the command)
- Capabilities: `trigger.session`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec` | output | execution | Start |  |

**Example:** Lock → pause music and mute the microphone.

### Login (`event.login@1`)

Starts the command once after the graphical session starts.

- Kind: event (starts the command)
- Capabilities: `trigger.session`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec` | output | execution | Start |  |

**Example:** Login → open mail and messenger.

### Manually (`event.manual@1`)

Starts the command by hand: from the command palette, a hotkey or `serpantinum-x run`. Any other event in the command makes it an automation.

- Kind: event (starts the command)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec` | output | execution | Start |  |
| `arg` | output | text | Argument |  |

**Example:** Manually → Notification "Hello".

### Monitor connected (`event.monitor_added@1`)

Starts the command when a monitor is connected (a name such as HDMI-A-1 can be given).

- Kind: event (starts the command)
- Capabilities: `trigger.windows`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `monitor_filter` | input | text | Monitor name |  |
| `exec` | output | execution | Start |  |
| `monitor` | output | text | Monitor |  |

**Example:** Second monitor connected → arrange windows.

### Monitor disconnected (`event.monitor_removed@1`)

Starts the command when a monitor is disconnected.

- Kind: event (starts the command)
- Capabilities: `trigger.windows`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `monitor_filter` | input | text | Monitor name |  |
| `exec` | output | execution | Start |  |
| `monitor` | output | text | Monitor |  |

**Example:** Second monitor disconnected → restore the wallpaper.

### Notification received (`event.notification.received@1`)

Fires when an application shows a notification (an application can be given). This is a SEPARATE right: the shell observes notification messages on the session bus. The title and text go only to this command and are never stored; only the application name is logged. Notifications from "Serpantinum" itself and updates of earlier notifications are skipped.

- Kind: event (starts the command)
- Capabilities: `trigger.notifications`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `app_filter` | input | text | Application |  |
| `exec` | output | execution | Start |  |
| `app` | output | text | Application |  |
| `title` | output | text | Title |  |
| `body` | output | text | Body |  |

**Example:** A Telegram notification arrived → flash a light.

### Server recovered (`event.server.recovered@1`)

Fires when a server that stopped responding answers again. It comes from the event log of the Servers section (read-only).

- Kind: event (starts the command)
- Capabilities: `trigger.servers`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `server_filter` | input | text | Server (name or id) |  |
| `exec` | output | execution | Start |  |
| `server` | output | text | Id |  |
| `server_name` | output | text | Server |  |
| `reason` | output | text | Note |  |

**Example:** Server is back → notification.

### Server unreachable (`event.server.unreachable@1`)

Fires when a server from the Servers section stops responding. It comes from the event log of the Servers section (read-only), so it fires while that section polls the servers.

- Kind: event (starts the command)
- Capabilities: `trigger.servers`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `server_filter` | input | text | Server (name or id) |  |
| `exec` | output | execution | Start |  |
| `server` | output | text | Id |  |
| `server_name` | output | text | Server |  |
| `reason` | output | text | Reason |  |

**Example:** A node went down → ask whether to restart it.

### Sunrise or sunset (`event.sun@1`)

Starts the command at sunrise or sunset (with an offset in minutes). Coordinates come from the shell's location settings.

- Kind: event (starts the command)
- Capabilities: `trigger.time`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `kind` | input | text | Event | sunset |
| `offset` | input | number | Offset, min | 0 |
| `exec` | output | execution | Start |  |
| `time` | output | time | Time | 00:00 |

**Example:** 15 minutes before sunset → night filter.

### At a given time (`event.time_at@1`)

Starts the command every day (or on the chosen days) at the given time. If the computer was asleep, «Missed run» decides what happens.

- Kind: event (starts the command)
- Capabilities: `trigger.time`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `at` | input | time | Time | 08:00 |
| `days` | input | text | Days | daily |
| `missed` | input | text | Missed run | skip |
| `exec` | output | execution | Start |  |
| `time` | output | time | Time | 00:00 |
| `weekday` | output | text | Weekday |  |

**Example:** At 08:00 on weekdays → notification "Stand-up".

### Screen unlocked (`event.unlock@1`)

Starts the command when the session is unlocked (systemd-logind signal).

- Kind: event (starts the command)
- Capabilities: `trigger.session`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec` | output | execution | Start |  |

**Example:** Unlock → restore audio.

### USB device connected (`event.usb.connected@1`)

Fires when a USB device is plugged in: by default a storage drive with a filesystem (flash drive, disk); "other" or "any" can be chosen. The source is udev (udevadm monitor), read-only.

- Kind: event (starts the command)
- Capabilities: `trigger.usb`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `kind_filter` | input | text | What | storage |
| `label_filter` | input | text | Label or name |  |
| `exec` | output | execution | Start |  |
| `label` | output | text | Label |  |
| `device` | output | text | Device |  |
| `kind` | output | text | Kind (storage or other) |  |

**Example:** A flash drive was plugged in → open it.

### VPN changed (`event.vpn.changed@1`)

Fires when our VPN turned on, turned off, changed node or failed to turn on (the source is the VPN module's event log, read-only; it touches neither the network nor the service). Gives the state, the node name and the failure reason.

- Kind: event (starts the command)
- Capabilities: `trigger.vpn`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `state_filter` | input | text | State | any |
| `exec` | output | execution | Start |  |
| `state` | output | text | State |  |
| `node` | output | text | Node |  |
| `connected` | output | yes/no | VPN on | False |
| `reason` | output | text | Reason |  |

**Example:** VPN failed → show a notification.

### Wi-Fi connected (`event.wifi.connected@1`)

Fires when the computer connects to a Wi-Fi network (a network name can be given). The source is NetworkManager (nmcli monitor), read-only: nothing is switched on or scanned.

- Kind: event (starts the command)
- Capabilities: `trigger.network`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `ssid_filter` | input | text | Network name |  |
| `exec` | output | execution | Start |  |
| `ssid` | output | text | Network |  |

**Example:** Connected to the home network → turn the sound on.

### Wi-Fi disconnected (`event.wifi.disconnected@1`)

Fires when the computer disconnects from a Wi-Fi network (a network name can be given). The source is NetworkManager (nmcli monitor), read-only. The counterpart of "Wi-Fi connected".

- Kind: event (starts the command)
- Capabilities: `trigger.network`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `ssid_filter` | input | text | Network name |  |
| `exec` | output | execution | Start |  |
| `ssid` | output | text | Network |  |

**Example:** Left the work network → turn the VPN off.

### Workspace switched (`event.workspace@1`)

Starts the command when you switch to a workspace (a specific one can be chosen).

- Kind: event (starts the command)
- Capabilities: `trigger.windows`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `workspace_filter` | input | text | Workspace |  |
| `exec` | output | execution | Start |  |
| `workspace` | output | text | Workspace |  |

**Example:** Switch to workspace 5 → quiet mode.

