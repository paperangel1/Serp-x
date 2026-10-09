# serp-x

A **modified build of [Serpantinum](https://github.com/ilyamiro/serpantinum)** by ilyamiro
(Quickshell desktop shell for Hyprland on Arch Linux). This is not the upstream project and is not
affiliated with it. Upstream's own README is [README.md](README.md).

Licensed under **AGPL-3.0-or-later** (see [LICENSE.md](LICENSE.md)). What this build changes in
upstream files is listed in [NOTICE](NOTICE); everything else is added on top.

## Install

Arch Linux (or an Arch derivative) on x86_64, as a normal user:

```bash
curl -fsSL https://raw.githubusercontent.com/paperangel1/Serp-x/main/installer/scripts/bootstrap.sh | bash
```

The script downloads the latest **numbered release**, checks the GPG signature of `SHA256SUMS`
against the key fingerprint pinned inside the script, checks the sha256 of every file, and only then
starts the installer (`serp-installer`, a terminal UI; `--plain` for line output). Any mismatch stops
the run. A specific release: `... | bash -s -- --version v2.2.5-s1`.

Release signing key: `8F84 E491 5C98 F28D FA1E 7F48 4E20 4597 1CEF 3BD0`
(`Serp-x release <paperangel1@users.noreply.github.com>`, public key in
[installer/release-key.asc](installer/release-key.asc)). The same fingerprint is pinned in
`bootstrap.sh` and in the updater.

Emergency path without prebuilt binaries: `... | bash -s -- --from-source --version <tag>`
(needs `go` and `git`, builds the installer from the tagged source).

## Modules

The installer lets you choose what to install (presets: full / minimal / custom); modules can be
added or removed later (`serp-installer`, or "Change modules" in the Updates tab).

| Module | What it is |
|---|---|
| core | the Serpantinum shell (upstream), Hyprland configs, the `serpantinum-x` CLI, logs, the Updates tab |
| vpn | own Xray VPN, Remnawave subscription, "Russia direct" mode (the service is installed disabled) |
| servers | server status from Remnawave and SSH commands |
| commands | visual automations and the `serpantinum-cmdd` daemon |
| commands-media | example commands: download video by link, audio from a clip (yt-dlp) |
| ai-gemini | changelog translation and the Gemini node in Commands (your own key) |
| hotkeys | hotkeys menu with search and your own bindings |
| tools | color picker with history, quick notes in a screen corner |
| ocr | text recognition button in the screenshot tool (Russian and English) |
| emoji | Noto Color Emoji across the whole shell |
| sddm | SDDM login screen with the Serpantinum theme |
| wallpapers | the full upstream wallpaper set |
| nvidia | open NVIDIA driver (DKMS) and Hyprland settings (not tested on hardware) |

## Updates

Installed copies update only from numbered, signed releases of this repository (tags like
`v2.2.5-s1`: upstream version plus this build's number). In the Updates tab, or:

```bash
serpantinum-x update run
```

Each update is verified (GPG against the pinned key, sha256), validated, backed up, applied, the
shell is restarted and checked; if it does not come up healthy, the previous version is restored
automatically. Settings: `~/.config/serpantinum-x/update.toml` (`channel`, `base_url`, `pubkey_fpr`).
Telemetry: none, anywhere.

## Credits

- **Serpantinum** by [ilyamiro](https://github.com/ilyamiro) and contributors (AGPL-3.0-or-later) -
  the shell this build is based on.
- This build adds the modules above, the installer and the update pipeline.
- Third-party software is installed from your distribution's packages or from official releases
  (for example Xray-core, with a pinned sha256).

## For maintainers

`installer/scripts/release.sh TAG` builds, signs and prints the `gh release create` command.
Tests: `src/scripts/custom/tests/*_test.sh`, `installer/scripts/test_bootstrap.sh`,
`cd installer && GOFLAGS=-mod=vendor go test ./...`.
