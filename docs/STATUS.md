# Status — 2026-11-21

## Where things are
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
