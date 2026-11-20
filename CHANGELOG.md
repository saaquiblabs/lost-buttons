# Changelog

## 0.3.4 — 2026-11-21

- Fix: right after an upgrade, `lost-buttons start` sometimes needed running again a few seconds
  later. It now keeps trying by itself for up to 30 seconds.

## 0.3.3 — 2026-11-21

- Started retrying once after an upgrade; not long enough.

## 0.3.2 — 2026-11-21

- Fix: after `brew upgrade`, macOS could still stop the new version from launching. macOS
  remembers the old version's deleted folder; `lost-buttons start` now makes it forget those.

## 0.3.1 — 2026-11-21

- Fix: after an upgrade, macOS could stop the new version from launching, because it still
  expected the old version's signature. `lost-buttons start` now registers the new version afresh.
- `lost-buttons start` now stops the old Homebrew service from 0.2 by itself, so upgrading is
  `brew upgrade lost-buttons` then `lost-buttons start`.
- `lost-buttons status` says when Lost Buttons is switched on but not actually running.

## 0.3.0 — 2026-11-21

- **Start it with `lost-buttons start`** instead of `brew services start`. Lost Buttons now runs as
  a proper macOS background item, so Login Items shows **Lost Buttons** with its icon, not a
  Homebrew entry. New: `lost-buttons stop` and `lost-buttons status`.
- After `brew upgrade`, run `lost-buttons start` again: it swaps the running copy for the new one.
- **Upgrading from 0.2:** `brew services stop lost-buttons` first, then `lost-buttons start`.
  macOS may ask for the two permissions once more.
- Needs macOS 13 Ventura or newer (was 12).
- README: a picture of what it does, upgrade steps and a list of commands.

## 0.2.1 — 2026-11-20

- Fix: the permission prompts and Login Items showed a gear and `lost-buttons` instead of the
  Lost Buttons icon and name. Homebrew keeps the app outside `/Applications`, where macOS doesn't
  register apps by itself; Lost Buttons now registers itself when it starts.

## 0.2.0 — 2026-11-20

- Now ships as **Lost Buttons.app**, so macOS shows its name and icon in Login Items, the
  Privacy & Security lists and the "background item added" notice, instead of a blank
  `lost-buttons` entry. The `lost-buttons` command works as before.
- Only one copy runs at a time, so a press is never sent twice (for example, if the app is
  double-clicked while the Homebrew service is running).
- **Upgrading from 0.1.0:** macOS sees this as a new program, so allow it once more. In
  System Settings → Privacy & Security → Input Monitoring and → Accessibility, remove the old
  `lost-buttons` entry (select it, click −) and switch on **Lost Buttons**.
- New: an easy setup guide at the top of the README, and [docs/PERFORMANCE.md](docs/PERFORMANCE.md)
  with measured CPU, memory and wakeups.

## 0.1.0 — 2026-11-20

- First release. Finds mice whose HID descriptor has unnamed button bits and delivers those
  buttons (4 = Back, 5 = Forward; ⌘[ / ⌘] in apps that ignore mouse buttons).
- `lost-buttons doctor` shows which connected mice are affected.
- Opens only affected mice; asks for permissions only when one is plugged in.
