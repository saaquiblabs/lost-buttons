# Status — 2026-11-20 14:41 IST

## Done
- v0.1.0 live: github.com/saaquiblabs/lost-buttons, tap saaquiblabs/homebrew-tap (`brew install saaquiblabs/tap/lost-buttons`).
- Detects unnamed button bits from each mouse's HID descriptor; opens only affected mice. 16 tests pass (`make test`).
- Measured: ~8.5 MB RSS, 0% CPU idle. Installed via brew on the home Mac (service NOT started yet).

## Not done / next
1. **Switch the home Mac over** (Chimera plugged in). The old helper `local.kreo-sidebuttons` (~/.local/share/kreo-sidebuttons) still runs: stop it first or presses fire twice:
   `launchctl bootout gui/$(id -u)/local.kreo-sidebuttons && brew services start lost-buttons && lost-buttons doctor`
   Grant Input Monitoring + Accessibility, test Back/Forward in Chrome and Finder.
2. **Real descriptor**: README's `doctor` sample for the Chimera (248a:5b4a) is a guess. Replace with real `lost-buttons doctor --raw` output and add the descriptor as a test.
3. **Logo**: first round (4 directions: Found, Back, Missing piece, Click ripple) on
   https://claude.ai/artifact/HGwraXxhqQFnrBJwXeUt4Q. Saaquib is **not fond of any** — needs a new round
   with a different approach (ask what he likes first; consider porting from an existing icon set per the reuse rule).
4. Office Mac: `brew install saaquiblabs/tap/lost-buttons && brew services start lost-buttons`.

## Also this session (not this repo)
- 14:20 IST "The file can't be found" dialog storm = leftover Karabiner-Elements services after the app was deleted.
  User-level ones stopped; root ones (Karabiner-Core-Service, VirtualHIDDevice daemon, hidden
  /Applications/.Karabiner-VirtualHIDDevice-Manager.app) go away on restart. If dialogs return after restart, remove them with sudo.
