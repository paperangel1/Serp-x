<!-- This file is generated from the node schema; do not edit it by hand. -->

## Actions

### Gemini (`action.ai.gemini@1`)

Asks Gemini to translate, explain or shorten a text, or to run your own prompt. NOTE: the text is sent to a Google service. The key is read from ~/.config/serpantinum/secrets/gemini_key and the request goes through a proxy if one is set in the settings (ai.proxy), with a fallback model. Text up to 8000 characters. The text and the answer are not logged. Needs the net.gemini right.

- Kind: latent (may wait)
- Capabilities: `net.gemini`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `mode` | input | text | Task | explain |
| `text` | input | text | Text |  |
| `language` | input | text | Answer language | ru |
| `prompt` | input | text | Prompt (for "custom prompt") |  |
| `exec_out` | output | execution | Done |  |
| `result` | output | text | Result |  |

**Example:** Explain the selected text in Russian.

### Microphone (`action.audio.mic_mute@1`)

Mutes or unmutes the default microphone. "toggle" flips the current state.

- Kind: action (follows the execution wire)
- Capabilities: `audio.mic`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `mode` | input | text | Mode | set |
| `muted` | input | yes/no | Mute |  |
| `exec_out` | output | execution | Done |  |
| `is_muted` | output | yes/no | Muted | False |

**Example:** Microphone: mute (restore at the end).

### Audio output (`action.audio.set_output@1`)

Makes an audio output device the default. The device is matched by name or description (a part of a word is enough, case does not matter). If none matches the error lists the available ones.

- Kind: action (follows the execution wire)
- Capabilities: `audio.output`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `device` | input | text | Device | headphones |
| `exec_out` | output | execution | Done |  |
| `name` | output | text | Device name |  |

**Example:** Audio output: "headphones".

### Volume (`action.audio.set_volume@1`)

Changes the default output's volume: set 0-100% ("set"), change by a number of percent ("change"), or mute control ("mute", "unmute", "toggle_mute"). Never goes above 100%.

- Kind: action (follows the execution wire)
- Capabilities: `audio.volume`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `mode` | input | text | Mode | set |
| `volume` | input | number | Volume, % | 40 |
| `delta` | input | number | Change by, % | 5 |
| `exec_out` | output | execution | Done |  |
| `level` | output | number | Result, % | 0 |
| `muted` | output | yes/no | Muted | False |

**Example:** Volume: 30%.

### Set clipboard (`action.clipboard_set@1`)

Puts text into the clipboard. It can restore the previous content when the command ends (the "restore" property).

- Kind: action (follows the execution wire)
- Capabilities: `clipboard.write`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `text` | input | text | Text |  |
| `exec_out` | output | execution | Done |  |

**Example:** Set clipboard to "https://example.org", then show a notification.

### Archive (`action.file.archive@1`)

Packs files and folders into a zip archive (symbolic links are not followed). The archive goes into the given folder or next to the first file; existing archives are never overwritten. The source files are not changed, so no restore is needed. Limit: 20000 files and 4 GB.

- Kind: action (follows the execution wire)
- Capabilities: `file.write`
- Changes state: yes
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `paths` | input | list (text) | Files |  |
| `name` | input | text | Archive name | archive.zip |
| `folder` | input | text | Archive folder |  |
| `allow_outside_home` | input | yes/no | Allow outside home | False |
| `exec_out` | output | execution | Done |  |
| `archive` | output | text | Archive |  |
| `count` | output | number | Files packed | 0 |

**Example:** An archive of the selected files.

### Convert images (`action.file.convert_image@1`)

Converts pictures with ImageMagick to webp, png or jpg with optional downscaling (never upscaling) and quality. The result is written next to the source or into the given folder; sources are untouched and nothing is overwritten. Takes one file or a list and returns the list of results.

- Kind: action (follows the execution wire)
- Capabilities: `image.convert`, `file.write`
- Changes state: yes
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `path` | input | text | File |  |
| `paths` | input | list (text) | Files (list) | [] |
| `format` | input | text | Format | webp |
| `max_width` | input | number | Max width | 1600 |
| `quality` | input | number | Quality | 85 |
| `folder` | input | text | Output folder |  |
| `allow_outside_home` | input | yes/no | Allow outside home | False |
| `exec_out` | output | execution | Done |  |
| `new_path` | output | text | Result |  |
| `new_paths` | output | list (text) | Results | [] |

**Example:** Convert the selected pictures to webp, 1600 pixels.

### Move or copy file (`action.file.move@1`)

Moves or copies a file into a folder (created when needed). Files are never overwritten: on a name clash " (1)" is added, or the file is skipped, or the command stops with an error. Works only inside the home folder; outside it, enable "Allow outside home" and approve the file.write.any right. Restore moves a moved file back (a copy is not deleted).

- Kind: action (follows the execution wire)
- Capabilities: `file.write`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `path` | input | text | File |  |
| `folder` | input | text | Folder |  |
| `mode` | input | text | Mode | move |
| `on_exists` | input | text | If the name is taken | rename |
| `create_folder` | input | yes/no | Create folder | True |
| `allow_outside_home` | input | yes/no | Allow outside home | False |
| `exec_out` | output | execution | Done |  |
| `new_path` | output | text | New path |  |

**Example:** Move a download into ~/Pictures/Sorted.

### Rename file (`action.file.rename@1`)

Changes the file name, keeping it in the same folder. Files are never overwritten: on a name clash " (1)" is added, or the step is skipped, or the command stops. The path rules are those of "Move file": the home folder only; outside it enable "Allow outside home" and the file.write.any right. Restore brings the old name back.

- Kind: action (follows the execution wire)
- Capabilities: `file.write`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `path` | input | text | File |  |
| `name` | input | text | New name |  |
| `on_exists` | input | text | If the name is taken | rename |
| `allow_outside_home` | input | yes/no | Allow outside home | False |
| `exec_out` | output | execution | Done |  |
| `new_path` | output | text | New path |  |

**Example:** Rename to report-2026.pdf.

### HTTP request (`action.http.request@1`)

Sends a GET or POST request and returns the status code and the text (up to 1 MB). There is a timeout; redirects only go to http and https. Headers are lines "Name: value"; a value like secret:name is read from ~/.config/serpantinum/secrets and never reaches the log. The URL and body are not logged, only the site and the status. Needs the net.http right: the command will be able to send data to the network.

- Kind: latent (may wait)
- Capabilities: `net.http`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `url` | input | text | URL |  |
| `method` | input | text | Method | GET |
| `headers` | input | text | Headers |  |
| `body` | input | text | Body |  |
| `timeout` | input | number | Timeout, s | 15 |
| `exec_out` | output | execution | Done |  |
| `status` | output | number | Status | 0 |
| `text` | output | text | Response |  |
| `ok` | output | yes/no | Success (2xx) | False |

**Example:** GET https://example.com/api.

### Media control (`action.media.control@1`)

Controls the media player (any MPRIS player: Spotify, a browser, mpv): play, pause, toggle, next, previous, stop. No player is not an error, the state is then "none". Restore at the end brings back the previous playing/paused state (not for next/previous).

- Kind: action (follows the execution wire)
- Capabilities: `media.control`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `command` | input | text | Action | pause |
| `player` | input | text | Player |  |
| `exec_out` | output | execution | Done |  |
| `state` | output | text | State |  |
| `title` | output | text | Track |  |

**Example:** Media: pause (restore at the end).

### Notification (`action.notify@1`)

Shows a desktop notification with a title and a body.

- Kind: action (follows the execution wire)
- Capabilities: `notify.show`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `title` | input | text | Title |  |
| `body` | input | text | Body |  |
| `exec_out` | output | execution | Done |  |

**Example:** Notification: "Done", "Files sorted".

### Open link (`action.open_link@1`)

Opens a link in the default browser (xdg-open). Only http, https and mailto are accepted: file:, javascript: and any other scheme is rejected with an error. The address is not logged (only the scheme).

- Kind: action (follows the execution wire)
- Capabilities: `link.open`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `url` | input | text | Link |  |
| `exec_out` | output | execution | Done |  |

**Example:** Open "https://example.org".

### Screenshot (`action.screenshot@1`)

Takes a screenshot with the shell's own tool (serpantinum screenshot): the whole screen, the active window or an area "x,y WxH". Without coordinates the "area" mode opens the usual area-selection overlay: you pick the area and the command does not learn the file path. The file goes to Pictures/Screenshots. The tool always copies the shot to the clipboard; with "copy: no" the previous clipboard text is put back (an image in the clipboard is not restored). The "File" output is the path of the shot.

- Kind: action (follows the execution wire)
- Capabilities: `screen.capture`
- Changes state: yes
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `mode` | input | text | What to capture | full |
| `geometry` | input | text | Area "x,y WxH" |  |
| `copy` | input | yes/no | Copy to clipboard | True |
| `exec_out` | output | execution | Done |  |
| `path` | output | text | File |  |

**Example:** Active window screenshot → show the file path.

### Server command (`action.server.run@1`)

Runs an allowed command on a server from the Servers section (by name or id) and returns its output. Dangerous commands (restart, update) ask for confirmation at run time; no answer in a minute means the command is not run. Commands that need the server name typed (reboot) are refused from automations unless "Allow the most dangerous" is on and the servers.run.typed right is approved. The output is not logged. It cannot be undone.

- Kind: latent (may wait)
- Capabilities: `servers.run`
- Changes state: yes
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `server` | input | text | Server (name or id) |  |
| `command` | input | text | Command (id, e.g. act-restart-node) |  |
| `allow_typed` | input | yes/no | Allow the most dangerous | False |
| `exec_out` | output | execution | Done |  |
| `output` | output | text | Output |  |
| `exit_code` | output | number | Exit code | 0 |

**Example:** Server vps: restart the node.

### Run shell command (`action.shell@1`)

Runs a command in bash as a separate process with a timeout and a trimmed environment (no secrets). Asks for confirmation on every run, even in automations; no answer cancels the run. Arbitrary commands cannot be rolled back.

- Kind: action (follows the execution wire)
- Capabilities: `exec.script`
- Changes state: yes
- Undo: none
- Danger: confirm

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `command` | input | text | Command |  |
| `timeout` | input | decimal number | Timeout, s | 10 |
| `arg` | input | text | Argument $1 |  |
| `exec_out` | output | execution | Done |  |
| `stdout` | output | text | Output |  |
| `exit_code` | output | number | Exit code | 0 |

**Example:** Run "date +%H:%M", show the output.

### Bar: show or hide (`action.shell.bar@1`)

Hides the shell's bar or brings it back ("toggle" flips it). It is the same "autohide" switch as in the bar settings: a hidden bar slides in when the pointer touches the screen edge. The previous state can be restored when the command ends (the "restore" property). Goes through the shell's own `xcmd` IPC target.

- Kind: action (follows the execution wire)
- Capabilities: `shell.bar`
- Changes state: yes
- Undo: end
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `mode` | input | text | Action | hide |
| `exec_out` | output | execution | Done |  |

**Example:** Bar: hide (restore at the end) for the length of a presentation.

### Screen brightness (`action.shell.brightness@1`)

Sets the screen brightness in percent ("set") or changes it by a number of percent ("delta"). Uses the shell's brightness script (backlight or DDC). Never goes below 1% so the screen cannot go fully dark.

- Kind: action (follows the execution wire)
- Capabilities: `screen.control`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `mode` | input | text | Mode | set |
| `percent` | input | number | Percent | 50 |
| `delta` | input | number | Change by, % | 10 |
| `exec_out` | output | execution | Done |  |
| `result` | output | number | Result, % | 0 |

**Example:** Brightness: 30%.

### Do not disturb (`action.shell.dnd@1`)

Turns the shell's do-not-disturb mode on or off (the same switch as in the notification panel): popups and sound are muted, urgent notifications still show, and notifications still land in the notification centre. Goes through the shell's own `xcmd` IPC target.

- Kind: action (follows the execution wire)
- Capabilities: `shell.dnd`
- Changes state: yes
- Undo: end
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `enabled` | input | yes/no | Enable |  |
| `exec_out` | output | execution | Done |  |

**Example:** Do not disturb: on (restore at the end).

### Night filter (`action.shell.night_filter@1`)

Turns the night filter (warm screen colour, the same as in the shell settings) on or off. Temperature in kelvin (1000-10000); 0 keeps the one saved in the settings.

- Kind: action (follows the execution wire)
- Capabilities: `screen.control`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `enabled` | input | yes/no | Enable |  |
| `temperature` | input | number | Temperature, K | 0 |
| `exec_out` | output | execution | Done |  |

**Example:** Night filter: on, 4000 K.

### Dark or light theme (`action.shell.theme@1`)

Switches the shell between dark and light theme ("toggle" flips it) and optionally the Matugen colour scheme. Colours are regenerated from the current wallpaper, so it takes a couple of seconds. Fully works with the Matugen theme; with a fixed palette only the mode is saved.

- Kind: action (follows the execution wire)
- Capabilities: `shell.theme`
- Changes state: yes
- Undo: end
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `mode` | input | text | Theme | dark |
| `scheme` | input | text | Colour scheme | keep |
| `exec_out` | output | execution | Done |  |

**Example:** Theme: dark (restore at the end).

### Set wallpaper (`action.shell.wallpaper@1`)

Sets the wallpaper on all monitors. A file is used as is; for a folder a random picture from it is picked. The previous wallpaper can be restored when the command ends (the "restore" property).

- Kind: action (follows the execution wire)
- Capabilities: `shell.wallpaper`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `path` | input | text | File or folder |  |
| `exec_out` | output | execution | Done |  |
| `chosen` | output | text | Chosen file |  |

**Example:** Set wallpaper: folder ~/Pictures/Wallpapers (random).

### Timer (`action.timer@1`)

Starts a countdown in the background and moves on at once (the "Started" output). When time is up the separate "Time is up" output fires, optionally with a notification at the start and the end. The command lives until the timer ends (so its policy timeout must be at least as long) and the restores ("restore at the end") run after it. Cancelling the command stops the timer. Unlike "Delay", the main chain does not stand still.

- Kind: latent (may wait)
- Capabilities: `notify.show`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `seconds` | input | decimal number | Seconds | 60 |
| `name` | input | text | Name |  |
| `notify_start` | input | yes/no | Notify at start | False |
| `notify_end` | input | yes/no | Notify at the end | True |
| `exec_out` | output | execution | Started |  |
| `finished` | output | execution | Time is up |  |

**Example:** Timer 25 minutes: turn do-not-disturb on at once and show a break notification at the end.

### VPN (`action.vpn.set@1`)

Turns our VPN from the VPN section on, off or switches it ("switch" picks another node by name or id; "toggle" flips it). Works through the shell (it lives in the session and may start the service); the command waits until the VPN is really on or off. Respects the module's rules: while Happ is running our VPN does NOT turn on (a clear error), and Commands never stop Happ. Turning the VPN off sends traffic directly.

- Kind: action (follows the execution wire)
- Capabilities: `vpn.control`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `mode` | input | text | Action | on |
| `node` | input | text | Node (name or id) |  |
| `exec_out` | output | execution | Done |  |
| `connected` | output | yes/no | VPN on | False |
| `node_name` | output | text | Node |  |

**Example:** VPN: on (restore at the end).

### Arrange windows (`action.window.arrange@1`)

Arranges open windows. "by_monitor": move windows to the chosen monitor's workspace; "workspaces": by an "app:number" list; "tile": gather windows on one workspace, the first two go left and right; "stack": gather on one workspace. Apps (window classes) are comma-separated, empty = all windows. Restore moves windows back to their old workspaces.

- Kind: action (follows the execution wire)
- Capabilities: `window.manage`
- Changes state: yes
- Undo: off
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `layout` | input | text | Layout | by_monitor |
| `monitor` | input | text | Monitor |  |
| `apps` | input | text | Apps |  |
| `workspace` | input | number | Workspace (0 = current) | 0 |
| `exec_out` | output | execution | Done |  |
| `moved` | output | number | Windows moved | 0 |

**Example:** Arrange: firefox and code windows to monitor HDMI-A-1.

### Close window (`action.window.close@1`)

Closes the active window or windows matching a class and/or title (substring or re:regex, both conditions together). The window gets a normal request to close (hyprctl closewindow): the app may ask about unsaved work. Without "all matching" only the most recently used match is closed. A closed window cannot be brought back.

- Kind: action (follows the execution wire)
- Capabilities: `window.close`
- Changes state: yes
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `mode` | input | text | Which windows | active |
| `class_filter` | input | text | Window class |  |
| `title_filter` | input | text | Title |  |
| `all` | input | yes/no | All matching | False |
| `exec_out` | output | execution | Done |  |
| `closed` | output | number | Windows closed | 0 |

**Example:** Close windows of class "Slack" after 18:00.

### Open app (`action.window.open_app@1`)

Starts an app on the chosen workspace without switching to it. The app is a desktop entry id (for example org.telegram.desktop) or a command (firefox, code). A missing app gives a clear error. It can wait for the window to appear.

- Kind: action (follows the execution wire)
- Capabilities: `window.manage`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `app` | input | text | App |  |
| `workspace` | input | number | Workspace | 1 |
| `wait` | input | number | Wait for window, s | 0 |
| `exec_out` | output | execution | Done |  |
| `address` | output | text | Window |  |

**Example:** Open "firefox" on workspace 2.

