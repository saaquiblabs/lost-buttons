# Status — 2026-11-21

## Learned the hard way (keep)
- macOS answers a running process from what it knew at start: a permission switched on later is not
  seen until restart. The service restarts itself while waiting (5 s → 30 s backoff); menu `r` = now.
- Every build is ad-hoc signed, so each upgrade is a new app to macOS: both permissions again, and
  old builds leave same-named entries whose switches don't apply. Menu → Fix permissions runs
  `tccutil reset ListenEvent|Accessibility com.saaquiblabs.lost-buttons` (needs the app registered).
- The permission prompt shows once per build; after that only the settings page helps.
- Test the menu with a fake service that holds the lock and writes the state file (no permissions
  needed); capture with `script` + `docs/img/source/ansi2html.py`.

## Where things are
- **Done 2026-11-21:** 0.4.4 working on the owner's Mac (Chimera fixed, both permissions). GitHub
  release page v0.4.4 (Latest). README: real menu screenshot, requirements, badges, acknowledgements,
  contributing; CONTRIBUTING / SECURITY / CODE_OF_CONDUCT, mouse report form; private vulnerability
  reporting on; repo topics set. Site PR najmushsaaquib/saaquiblabs#87 updated, **[HUMAN] merge it**.
- Next project: claude-code-voice, something similar and better (native app). Reuse what 0.4.x
  taught (below) and its notifier ADR 0003.
- **0.4.4 released** (menu: icon, live status, r, Fix permissions, Show the app in Finder).
- **0.4.0 released** (tag + `saaquiblabs/tap` formula) and running on the owner's Mac via
  `brew services`. Runs as `Lost Buttons.app` (name + icon). `lost-buttons` alone opens a terminal menu
  (Sources/Menu.swift): status, start/stop, check mice, open each permission setting.
- README: picture at the top (`docs/img/lost-buttons.png`, rendered from saaquiblabs
  `scripts/brand/lb-scene/`), menu picture (`docs/img/menu.png`, source in `docs/img/source/`).
- saaquiblabs.com: picture instead of terminal + link to this repo, PR najmushsaaquib/saaquiblabs#87.

## Tried and dropped: 0.3.x (own login item via SMAppService)
Login Items showed "Lost Buttons" with its icon, but after every `brew upgrade` macOS killed the new
build at launch (`OS_REASON_CODESIGNING`; the job's launch requirement pins the old ad-hoc cdhash).
A second `lost-buttons start` later fixed it; nothing in-process did (unregister/re-register, waits,
re-exec, `lsregister -u` of deleted copies). Root cause is ad-hoc signing. Revisit only with an Apple
Developer ID (team-ID requirement), which also stops permissions resetting on each upgrade.

## Next (owner decides)
- Proper Mac app: downloadable, menu-bar UI with permission onboarding (port from LinearMouse, MIT),
  Developer ID + notarisation ($99/yr). About a day.
- Optional: post banners from the app itself (claude-code-voice's approach, ADR 0003 there) e.g.
  "Lost Buttons needs Accessibility" with a click to open the setting.
