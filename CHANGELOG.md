# Changelog

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
