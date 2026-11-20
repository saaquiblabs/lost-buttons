# Contributing to Lost Buttons

Thank you for helping. The most useful thing anyone can send is a report of a mouse whose buttons
macOS drops: open a [mouse report](https://github.com/saaquiblabs/lost-buttons/issues/new?template=mouse.yml)
with the output of `lost-buttons doctor --raw`.

## Build and test

You need macOS 12 or newer and the Xcode Command Line Tools (`xcode-select --install`). There are
no other dependencies.

```bash
make test        # the descriptor parser tests (Tests/main.swift)
make app         # build/Lost Buttons.app
"build/Lost Buttons.app/Contents/MacOS/lost-buttons"          # the menu
"build/Lost Buttons.app/Contents/MacOS/lost-buttons" doctor
```

To try the background part, stop the Homebrew service first (`brew services stop lost-buttons`), then
run `"build/Lost Buttons.app/Contents/MacOS/lost-buttons" run` in a terminal. Every build is a new
program to macOS, so it asks for Input Monitoring and Accessibility again.

## Adding a mouse

If a mouse's descriptor isn't handled, save it under `docs/descriptors/` (see the Kreo Chimera one) and
add a test for it in `Tests/main.swift`, so it stays fixed.

## Sending a change

- One change per pull request, with a short description of what and why.
- `make test` passes.
- Keep it small and dependency-free: no networking, no root, nothing that opens devices that don't
  need fixing. Those promises are in the README.
- Add a line to `CHANGELOG.md` under a new version heading.

By sending a pull request you agree that your change is released under the MIT licence.
