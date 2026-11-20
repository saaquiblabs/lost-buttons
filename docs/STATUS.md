# Status — 2026-11-20 16:20 IST (handoff to a fresh session)

Lost Buttons work for the next session. Other work from the same session (Mac sweep, saaquiblabs
org move, Phase 5, Cloudflare, MihrabUmmah badge) is in a private local note, not in this public repo.

## Done this session
- Logo: final icon (ChatGPT render, 3/4 palm mouse, tangerine squircle) in `docs/logo/`, README header,
  social preview uploaded by the owner. d-tox social preview uploaded too.
- saaquiblabs.com lists Lost Buttons on its Work page and in its link-preview card.
- Old helper `local.kreo-sidebuttons` removed completely: unloaded, plist and
  `~/.local/share/kreo-sidebuttons` moved to `~/.Trash`. **[HUMAN]** remove `kreo-sidebuttons` from
  System Settings → Privacy & Security → Input Monitoring and Accessibility (select, click −).
- Lost Buttons running via `brew services` (`sh.brew.lost-buttons`). With the Chimera plugged in,
  `lost-buttons doctor` says: `K Chimera [248a:5b4a] via USB — Fixable: buttons 4–5 are sent but never
  named...` (the README sample was right). Also seen: `Kreo Swarm [258a:010c]` OK. Raw descriptor saved:
  `docs/descriptors/kreo-chimera-248a-5b4a.txt`.
- Idle benchmark (mouse unplugged, 60 s, `top -stats cpu,mem,idlew,power,threads` + `ps -o time`):
  0.00 s CPU, 0 idle wakeups, power 0.0, 1 thread, RSS 5–7 MB, no sockets (`lsof -i`), 8 open files.

## 1. Lost Buttons: finish the switch-over (do first, mouse is plugged in)
1. Confirm the owner allowed Input Monitoring + Accessibility for `lost-buttons`; test Back/Forward in
   Chrome and Finder (Finder/Safari get ⌘[ / ⌘]).
2. Active benchmark: sample 60 s while the owner moves and clicks (same commands as above); note CPU
   and wakeups per second.
3. Add the saved descriptor as a test in `Tests/main.swift` (expects buttons 4–5 unnamed), `make test`.

## 2. Lost Buttons v0.2.0 (owner said start it)
- **App bundle, so macOS shows our icon and name.** Today the notification, Login Items and the
  Privacy lists show a generic "exec"/gear icon and `lost-buttons`, because it's a bare binary. Ship
  `Lost Buttons.app` (Info.plist with `CFBundleIdentifier` e.g. `com.saaquiblabs.lost-buttons`,
  `LSUIElement` true, `CFBundleIconFile`, `.icns` from `docs/logo/lost-buttons-1024.png` via `iconutil`),
  binary inside `Contents/MacOS/`. `/opt/homebrew/bin/lost-buttons` stays a symlink/wrapper so the CLI
  works. Update the Homebrew formula in `../homebrew-tap` (build the bundle into `prefix`, service runs
  the bundle's binary). Note in CHANGELOG/README: permissions must be granted again once (new identity).
  Check first how other brew-installed menu-less agents do this (reuse rule: port, don't invent).
- **Easy guide** at the top of README: install → start → plug in → allow two prompts → test → doctor.
- **Screenshots** (after the bundle, so they show the icon): real `doctor` output, the two permission
  prompts / Privacy entries, Login Items row. Images in `docs/img/`. No video without asking.
- **Performance page** `docs/PERFORMANCE.md`: idle + active numbers, method, commands to reproduce.
- Release: tag v0.2.0, update the tap formula (url + sha256), `brew upgrade` on this Mac, re-grant.
- Office Mac: `brew install saaquiblabs/tap/lost-buttons && brew services start lost-buttons`.

