#!/usr/bin/env bash
# Captures the real `lost-buttons` menu as docs/img/menu.png: runs it in a 90×44 pseudo-terminal,
# keeps the last frame, turns its colours into HTML (ansi2html.py) and screenshots that with
# headless Chrome. Run from the repo root after `make app`, with Lost Buttons running and permissions
# allowed, so it shows the everyday state. TERM_PROGRAM=ghostty makes the menu send its icon.
set -euo pipefail
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
( sleep 2; printf 'q' ) | script -q "$tmp/menu.raw" /bin/zsh -c \
  'stty cols 90 rows 44; TERM_PROGRAM=ghostty "build/Lost Buttons.app/Contents/MacOS/lost-buttons"' >/dev/null 2>&1
python3 docs/img/source/ansi2html.py "$tmp/menu.raw" > "$tmp/menu.html"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=720,600 --screenshot="$PWD/docs/img/menu.png" "file://$tmp/menu.html" >/dev/null 2>&1
echo "wrote docs/img/menu.png"
