# Security and capabilities

Every node declares its **capabilities** in advance: for example `audio.control`, `window.manage`, `file.write`, `net.http`, `exec.script`, `ssh.server`, `net.gemini`, `servers.run`, `trigger.clipboard`, `trigger.notifications`, `vpn.control`, `window.close`, `screen.capture`. A command's capabilities are the union of its nodes' capabilities.

- An automation does not start until you approve its rights: «This command will be able to: …». If nodes change and the rights grow, you must approve again.
- Imported commands and gallery copies are **disabled**, rights unapproved, triggers off. Nothing runs when a file is opened.
- Script, HTTP, SSH and file writes are sensitive: they are flagged in the rights list. A script runs as a separate process with a timeout and a trimmed environment; a dangerous action asks for confirmation on every run, even in an automation.
- Rights with an explicit text in the approval window: reading the clipboard and notifications (and that the content is never stored), sending the selected text to Gemini (a Google service), network (`net.http`), commands on servers, VPN control (on and off without asking; Commands never touch Happ), closing windows, screenshots. Server commands that need the name typed (reboot) are not run from automations without the separate `servers.run.typed` right.
- Files are touched only inside explicitly allowed roots; deleting only goes to the trash.
- Secrets are never stored in command files (use `secret:name`) and are masked in logs.
- Loop protection: a runs-per-minute limit and a run time limit (`policy`).
