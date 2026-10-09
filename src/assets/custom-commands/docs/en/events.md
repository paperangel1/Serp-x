# Events

An event starts a command. An event node has no «Run» input: it only has outputs, and the execution order begins at one of them (`exec`).

Events are: manual start (palette, hotkey, `serpantinum-x run`), time and interval, sunrise and sunset, windows opening and closing, workspace changes, a monitor connecting, session lock and idle, headphones, a link in the clipboard, a new file in a folder, a server going down or coming back, Wi-Fi (connected and disconnected), a USB drive, an app notification, a Bluetooth device, a VPN state change, a copied colour or phone number.

- A command with an event other than «Manual» is an **automation**. It can be turned on and off.
- Event outputs (for example the window «Class») are data for the other nodes.
- An event may fire while the previous run is still going: by default the extra run is skipped (`policy.reentrancy`) and runs per minute are limited.
- Several events read private data and need a separate right when you enable the command: **a link, colour or phone number in the clipboard** (one right, `trigger.clipboard`) and **notification** (`trigger.notifications`). Only this command gets the clipboard content or the notification text: they never reach the log or `cmd events`, only the kind, the length, the domain of a link and the app name do.
- A new file in a folder fires once the file has «settled» (its size has not changed for 3 seconds); partial downloads (`.part`, `.crdownload`, `.tmp`) and hidden files are skipped.
- The opposite event (unlock after lock) is made with a second chain in the same command.

Nodes that the shell does not have yet are shown in the gallery as «waiting for nodes» (there are none now).
