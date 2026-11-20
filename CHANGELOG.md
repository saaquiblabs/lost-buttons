# Changelog

## 0.1.0 — 2026-11-20

- First release. Finds mice whose HID descriptor has unnamed button bits and delivers those
  buttons (4 = Back, 5 = Forward; ⌘[ / ⌘] in apps that ignore mouse buttons).
- `lost-buttons doctor` shows which connected mice are affected.
- Opens only affected mice; asks for permissions only when one is plugged in.
