This build's own changes. Upstream's CHANGELOG.md is left untouched so that
merging a new upstream version never conflicts here.

### 2.2.5-s1

- feat(release): signed numbered releases on GitHub; `release` update channel (GPG against a pinned key, sha256, refuses downgrades, backup and automatic rollback), one-line install via bootstrap.sh
- feat(release): installer/scripts/release.sh builds, signs and prints the `gh release create` command
- docs: README-serp-x.md (install, modules, credits); upstream README.md only gets a 3-line pointer
- merge: upstream 2.2.5 (ScreenSaver idle inhibit for games, lsp-plugins-lv2 for the equalizer)
- fix(vpn): repeated or concurrent connect/disconnect/toggle clicks are dropped, the toggle has an explicit intent (no more double toggle)
- feat(installer): serp-installer is finished and tested in a QEMU VM on 9 scenarios (fresh install, repair, modules, uninstall, backup/restore, install over upstream, errors)
- fix(installer): installs python-jeepney (new upstream dependency); install over an upstream install makes a backup first; clearer "no internet" and "not enough disk space" messages
- fix(tests): update and log-redaction tests no longer depend on the version number or the home path
- chore: the changelog of this build lives in CHANGELOG-serp-x.md, upstream CHANGELOG.md is untouched

### 2.2.4-s1

- feat(updates): "Change modules" and "Backup" buttons in the Updates tab (shown only when the installer is present)
- feat(cli): serpantinum-x backup export|import, a wrapper over the installer (backups hold no secrets)
- feat(installer): serp-installer, a terminal installer with module selection, repair, uninstall and backups
- chore: remove telemetry completely (no code, no flag, no identifier)
- chore: tools/reinventory.sh lists the changes made on top of upstream and checks them against NOTICE
