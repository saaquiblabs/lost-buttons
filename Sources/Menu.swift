// The menu `lost-buttons` shows when you run it yourself in a terminal: status at the top, a short
// list you move through with the arrow keys, Enter to choose. Layout and keys follow ccstatusline's
// configuration menu (sirmalloc/ccstatusline, MIT). That one is built with Ink, a JavaScript library,
// so its code can't come along into a dependency-free Swift tool; this is a plain termios version.
// Run by launchd (no terminal attached), `lost-buttons` keeps doing its job instead: run().
import AppKit
import IOKit
import IOKit.hid

let interactive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1

private let tangerine = "\u{1B}[38;5;208m", bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m"
private let green = "\u{1B}[32m"

/// Is the background copy running? It holds the lock `run()` takes (isAlreadyRunning).
func backgroundRunning() -> Bool {
  let fd = open(NSTemporaryDirectory() + "lost-buttons.lock", O_CREAT | O_RDWR, 0o600)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
  return true
}

/// Names of the connected mice that have buttons macOS drops.
func affectedMice() -> [String] {
  var iterator: io_iterator_t = 0
  guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == KERN_SUCCESS
  else { return [] }
  defer { IOObjectRelease(iterator) }
  var names: [String] = []
  while case let service = IOIteratorNext(iterator), service != 0 {
    defer { IOObjectRelease(service) }
    if let bytes = descriptor(service), hasButtons(bytes), !findHiddenButtons(bytes).isEmpty {
      names.append(property(service, kIOHIDProductKey) as? String ?? "a mouse")
    }
  }
  return names
}

/// Runs a command with the terminal attached, so its own output shows.
@discardableResult
func shell(_ command: String) -> Int32 {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/zsh")
  p.arguments = ["-lc", command]  // -l: the login PATH, so Homebrew's `brew` is found
  guard (try? p.run()) != nil else { return -1 }
  p.waitUntilExit()
  return p.terminationStatus
}

func openSettings(_ pane: String) {
  NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
}

// MARK: - terminal

private var saved = termios()

private func rawMode(_ on: Bool) {
  if on {
    tcgetattr(STDIN_FILENO, &saved)
    var raw = saved
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    print("\u{1B}[?25l", terminator: "")  // hide the cursor
  } else {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
    print("\u{1B}[?25h", terminator: "")
  }
  fflush(stdout)
}

private enum Key { case up, down, enter, quit, digit(Int), other }

private func readKey() -> Key {
  var c: UInt8 = 0
  guard read(STDIN_FILENO, &c, 1) == 1 else { return .quit }
  switch c {
  case 0x1B:  // Esc alone quits; Esc [ A / Esc [ B are the arrows
    var seq = [UInt8](repeating: 0, count: 2)
    var flags = fcntl(STDIN_FILENO, F_GETFL)
    _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)
    usleep(20_000)
    let n = read(STDIN_FILENO, &seq, 2)
    flags = fcntl(STDIN_FILENO, F_GETFL)
    _ = fcntl(STDIN_FILENO, F_SETFL, flags & ~O_NONBLOCK)
    if n == 2 && seq[0] == 0x5B { return seq[1] == 0x41 ? .up : seq[1] == 0x42 ? .down : .other }
    return .quit
  case 0x0A, 0x0D: return .enter
  case UInt8(ascii: "k"): return .up
  case UInt8(ascii: "j"): return .down
  case UInt8(ascii: "q"): return .quit
  case UInt8(ascii: "1")...UInt8(ascii: "9"): return .digit(Int(c - UInt8(ascii: "0")))
  default: return .other
  }
}

private func waitForKey() {
  print("\n\(dim)Press any key to go back.\(reset)", terminator: "")
  fflush(stdout)
  rawMode(true)
  _ = readKey()
  rawMode(false)
}

// MARK: - menu

private struct Item { let label: String; let hint: String; let action: () -> Void }

func menu() {
  signal(SIGINT) { _ in tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved); print("\u{1B}[?25h"); exit(0) }
  var at = 0
  while true {
    let running = backgroundRunning()
    let mice = affectedMice()
    let items: [Item] = [
      running
        ? Item(label: "Stop Lost Buttons", hint: "Stops it now and at every login.",
               action: { shell("brew services stop lost-buttons") })
        : Item(label: "Start Lost Buttons", hint: "Runs it in the background now and at every login.",
               action: { shell("brew services start lost-buttons") }),
      Item(label: "Check my mice", hint: "Which connected mice have buttons macOS drops.",
           action: { doctor(raw: false); waitForKey() }),
      Item(label: "Allow Input Monitoring", hint: "Opens the setting. Switch on Lost Buttons there.",
           action: { openSettings("Privacy_ListenEvent") }),
      Item(label: "Allow Accessibility", hint: "Opens the setting. Switch on Lost Buttons there.",
           action: { openSettings("Privacy_Accessibility") }),
      Item(label: "Quit", hint: "Lost Buttons keeps running in the background.", action: {}),
    ]
    at = min(at, items.count - 1)

    print("\u{1B}[2J\u{1B}[H", terminator: "")  // clear the screen
    print("\n  \(tangerine)\(bold)Lost Buttons\(reset) \(dim)\(version)\(reset)\n")
    print(running ? "  \(green)●\(reset) Running in the background" : "  \(dim)○\(reset) Not running")
    print(mice.isEmpty
      ? "  \(dim)No mouse with dropped buttons is plugged in.\(reset)"
      : "  \(running ? "Fixing" : "Can fix"): \(mice.joined(separator: ", "))")
    print("")
    for (i, item) in items.enumerated() {
      print(i == at
        ? "  \(tangerine)▶ \(bold)\(item.label)\(reset)"
        : "    \(item.label)")
    }
    print("\n  \(dim)\(items[at].hint)\(reset)")
    print("\n  \(dim)↑↓ move · Enter choose · Esc quit\(reset)", terminator: "")
    fflush(stdout)

    rawMode(true)
    let key = readKey()
    rawMode(false)
    var chosen: Int?
    switch key {
    case .up: at = (at - 1 + items.count) % items.count
    case .down: at = (at + 1) % items.count
    case .enter: chosen = at
    case .digit(let d) where d <= items.count: chosen = d - 1
    case .quit: chosen = items.count - 1
    default: break
    }
    guard let c = chosen else { continue }
    if c == items.count - 1 { print("\n"); return }
    print("\u{1B}[2J\u{1B}[H", terminator: "")
    items[c].action()
    if c == 0 { Thread.sleep(forTimeInterval: 1) }  // let the service come up before the status line
  }
}
