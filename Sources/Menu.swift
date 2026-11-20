// The menu `lost-buttons` shows when you run it yourself in a terminal. Full screen (the terminal's
// alternate screen, so your scrollback is left as it was): the app icon drawn in coloured
// half-blocks, live status from the running copy (State.swift), the next useful action already
// picked, arrow keys and Enter. Keys and the overall shape follow ccstatusline's configuration menu
// (sirmalloc/ccstatusline, MIT). That one is built with Ink, a JavaScript library, so its code can't
// come along into a dependency-free Swift tool; this is plain termios and ANSI.
// Run by launchd (no terminal attached), `lost-buttons` does its job instead: run().
import AppKit
import IOKit
import IOKit.hid

let interactive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1

// MARK: - colours (24-bit; the icon's own: tangerine, cream, navy)

private let esc = "\u{1B}["
private func fg(_ r: Int, _ g: Int, _ b: Int) -> String { "\(esc)38;2;\(r);\(g);\(b)m" }
private func bg(_ r: Int, _ g: Int, _ b: Int) -> String { "\(esc)48;2;\(r);\(g);\(b)m" }
private let tangerine = fg(255, 122, 51), cream = fg(244, 235, 221), green = fg(95, 211, 138)
private let amber = fg(255, 196, 77), muted = fg(138, 145, 156), line = fg(70, 76, 88)
private let bold = "\(esc)1m", reset = "\(esc)0m"
private let selectedRow = bg(52, 40, 34)

// MARK: - status

/// Is the background copy running? It holds the lock `run()` takes (isAlreadyRunning).
func backgroundRunning() -> Bool {
  let fd = open(NSTemporaryDirectory() + "lost-buttons.lock", O_CREAT | O_RDWR, 0o600)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
  return true
}

/// Names of the connected mice that have buttons macOS drops. Reading descriptors needs no permission.
func affectedMice() -> [String] {
  var iterator: io_iterator_t = 0
  guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == KERN_SUCCESS
  else { return [] }
  defer { IOObjectRelease(iterator) }
  var names: [String] = []
  while case let service = IOIteratorNext(iterator), service != 0 {
    defer { IOObjectRelease(service) }
    if let bytes = descriptor(service), hasButtons(bytes), !findHiddenButtons(bytes).isEmpty {
      names.append(property(service, kIOHIDProductKey) as? String ?? "A mouse")
    }
  }
  return Array(Set(names)).sorted()  // a mouse can show up as several HID interfaces
}

private struct Status {
  var running: Bool
  var state: ServiceState?
  var mice: [String]

  static func now() -> Status {
    let running = backgroundRunning()
    var state: ServiceState?
    if running, let old = readState() {
      kill(old.pid, SIGUSR1)  // ask for a fresh one: permissions may have just changed
      usleep(120_000)
      state = readState()
    }
    return Status(running: running, state: state, mice: affectedMice())
  }

  var needsInputMonitoring: Bool { running && state?.inputMonitoring == false && !mice.isEmpty }
  var needsAccessibility: Bool { running && state?.accessibility == false && !mice.isEmpty }
}

// MARK: - terminal

private var saved = termios()

private func rawMode(_ on: Bool) {
  if on {
    tcgetattr(STDIN_FILENO, &saved)
    var raw = saved
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
  } else {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
  }
}

private func screen(_ on: Bool) {
  print(on ? "\(esc)?1049h\(esc)?25l" : "\(esc)?25h\(esc)?1049l", terminator: "")  // alternate screen, cursor
  fflush(stdout)
}

private func columns() -> Int {
  var w = winsize()
  return ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_col > 0 ? Int(w.ws_col) : 80
}

private enum Key { case up, down, enter, quit, digit(Int), none, other }

/// Waits up to `timeout` ms for a key; .none when nothing came (time to refresh the status).
private func readKey(timeout: Int32) -> Key {
  var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
  guard poll(&fds, 1, timeout) > 0 else { return .none }
  var c: UInt8 = 0
  guard read(STDIN_FILENO, &c, 1) == 1 else { return .quit }
  switch c {
  case 0x1B:  // Esc alone quits; Esc [ A / Esc [ B are the arrows
    var seq = [UInt8](repeating: 0, count: 2)
    var more = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&more, 1, 30) > 0, read(STDIN_FILENO, &seq, 2) == 2, seq[0] == 0x5B else { return .quit }
    return seq[1] == 0x41 ? .up : seq[1] == 0x42 ? .down : .other
  case 0x0A, 0x0D: return .enter
  case UInt8(ascii: "k"): return .up
  case UInt8(ascii: "j"): return .down
  case UInt8(ascii: "q"): return .quit
  case UInt8(ascii: "1")...UInt8(ascii: "9"): return .digit(Int(c - UInt8(ascii: "0")))
  default: return .other
  }
}

/// Characters a line takes on screen, without its colour codes.
private func width(_ s: String) -> Int {
  var n = 0, inCode = false
  for ch in s.unicodeScalars {
    if inCode { if ch == "m" { inCode = false }; continue }
    if ch == "\u{1B}" { inCode = true; continue }
    n += 1
  }
  return n
}

private func pad(_ s: String, _ to: Int) -> String { s + String(repeating: " ", count: max(0, to - width(s))) }

// MARK: - the icon, in half-blocks

/// The app icon as `rows` lines of "▀" characters: each one shows two pixels, the top one as the
/// text colour and the bottom one as the background. Empty when the icon can't be found (a build
/// outside the app bundle).
private func iconLines(rows: Int) -> [String] {
  guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
        let image = NSImage(contentsOf: url) else { return [] }
  let size = rows * 2
  guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return [] }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  let trim = Double(size) * 0.06  // the icon file has a transparent margin; draw past it
  image.draw(in: NSRect(x: -trim, y: -trim, width: Double(size) + 2 * trim, height: Double(size) + 2 * trim))
  NSGraphicsContext.restoreGraphicsState()

  func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int)? {
    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { return nil }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
  }
  return (0..<rows).map { row in
    var s = ""
    for x in 0..<size {
      switch (pixel(x, row * 2), pixel(x, row * 2 + 1)) {
      case let (t?, b?): s += fg(t.r, t.g, t.b) + bg(b.r, b.g, b.b) + "▀"
      case let (t?, nil): s += "\(esc)49m" + fg(t.r, t.g, t.b) + "▀"
      case let (nil, b?): s += "\(esc)49m" + fg(b.r, b.g, b.b) + "▄"
      case (nil, nil): s += "\(esc)49m "
      }
    }
    return s + reset
  }
}

// MARK: - menu

private struct Item {
  let label: String
  let badge: String  // right-hand note: "needed", "✓ allowed", "fixes K Chimera"
  let hint: String
  let action: () -> Void
}

/// Runs a command quietly; on failure shows what it printed.
private func quietly(_ command: String) {
  let p = Process(), out = Pipe()
  p.executableURL = URL(fileURLWithPath: "/bin/zsh")
  p.arguments = ["-lc", command]  // -l: the login PATH, so Homebrew's `brew` is found
  p.standardOutput = out
  p.standardError = out
  guard (try? p.run()) != nil else { return }
  let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  p.waitUntilExit()
  if p.terminationStatus != 0 { showText("\(amber)That didn't work:\(reset)\n\n" + text) }
}

private func showText(_ text: String) {
  print("\(esc)2J\(esc)H\n", terminator: "")
  for l in text.split(separator: "\n", omittingEmptySubsequences: false) { print("  " + l) }
  print("\n  \(muted)Press any key to go back.\(reset)", terminator: "")
  fflush(stdout)
  while case .none = readKey(timeout: 60_000) {}
}

private func openSettings(_ pane: String) {
  NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
}

private func items(_ s: Status) -> [Item] {
  let mice = s.mice.joined(separator: ", ")
  let im = !s.running || s.state == nil ? "" : s.state!.inputMonitoring ? "\(green)✓ allowed" : "\(amber)needed"
  let ax = !s.running || s.state == nil ? "" : s.state!.accessibility ? "\(green)✓ allowed" : "\(amber)needed"
  return [
    s.running
      ? Item(label: "Stop Lost Buttons", badge: "", hint: "Stops it now and at every login. Your side buttons stop working.",
             action: { quietly("brew services stop lost-buttons") })
      : Item(label: "Start Lost Buttons", badge: s.mice.isEmpty ? "" : "\(tangerine)fixes \(mice)",
             hint: "Runs it in the background, now and at every login.",
             action: { quietly("brew services start lost-buttons"); usleep(800_000) }),
    Item(label: "Allow Input Monitoring", badge: im,
         hint: "Opens the setting. Switch on Lost Buttons there (it reads the hidden buttons).",
         action: { openSettings("Privacy_ListenEvent") }),
    Item(label: "Allow Accessibility", badge: ax,
         hint: "Opens the setting. Switch on Lost Buttons there (it sends Back and Forward to apps).",
         action: { openSettings("Privacy_Accessibility") }),
    Item(label: "Check my mice", badge: "", hint: "Lists every connected mouse and whether macOS drops its buttons.",
         action: {
           let p = Pipe(), saved = dup(STDOUT_FILENO)
           dup2(p.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
           doctor(raw: false)
           fflush(stdout)
           dup2(saved, STDOUT_FILENO)
           close(saved)
           try? p.fileHandleForWriting.close()
           showText(String(decoding: p.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
         }),
    Item(label: "Quit", badge: "", hint: "Lost Buttons keeps running in the background.", action: {}),
  ]
}

/// The most useful item for the state things are in: start it, then the missing permissions.
private func suggested(_ s: Status) -> Int {
  if !s.running { return 0 }
  if s.needsInputMonitoring { return 1 }
  if s.needsAccessibility { return 2 }
  return 4
}

private func statusLines(_ s: Status) -> [String] {
  var out: [String] = []
  out.append(s.running
    ? "\(green)●\(reset) Running in the background"
    : "\(muted)○\(reset) Not running \(muted)— choose Start below\(reset)")
  if s.mice.isEmpty {
    out.append("\(muted)○\(reset) No mouse with dropped buttons plugged in \(muted)(nothing to fix)\(reset)")
  }
  for m in s.mice {
    let fixing = s.state?.fixing.contains(m) == true
    if !s.running {
      out.append("\(amber)●\(reset) \(bold)\(m)\(reset)  side buttons don't work yet")
    } else if s.needsInputMonitoring {
      out.append("\(amber)●\(reset) \(bold)\(m)\(reset)  waiting for Input Monitoring")
    } else if s.needsAccessibility {
      out.append("\(amber)●\(reset) \(bold)\(m)\(reset)  waiting for Accessibility")
    } else if fixing {
      out.append("\(green)●\(reset) \(bold)\(m)\(reset)  Back and Forward work")
    } else {
      out.append("\(amber)●\(reset) \(bold)\(m)\(reset)  just connected…")
    }
  }
  return out
}

private func draw(_ s: Status, _ list: [Item], at: Int) {
  let w = min(72, columns() - 4)  // inner width
  let icon = iconLines(rows: 8)
  var o = "\(esc)H\(esc)2J\n"
  func row(_ text: String, highlight: Bool = false) {
    o += "  \(line)│\(reset)" + (highlight ? selectedRow : "") + pad(text, w) + reset + "\(line)│\(reset)\n"
  }
  func rule(_ l: String, _ r: String) { o += "  \(line)\(l)" + String(repeating: "─", count: w) + "\(r)\(reset)\n" }

  rule("╭", "╮")
  let title = [
    "",
    "",
    "\(tangerine)\(bold)Lost Buttons\(reset)  \(muted)v\(version)\(reset)",
    "\(cream)Your mouse's side buttons, back on the Mac.\(reset)",
    "",
    "\(muted)Free and open source · by Saaquib Labs\(reset)",
    "",
    "",
  ]
  row("")
  for i in 0..<title.count {
    let left = icon.isEmpty ? "" : "  " + icon[i] + "   "
    row(left + title[i])
  }
  row("")
  rule("├", "┤")
  row("")
  row("  \(muted)STATUS\(reset)")
  for l in statusLines(s) { row("  " + l) }
  row("")
  rule("├", "┤")
  row("")
  for (i, item) in list.enumerated() {
    let mark = i == at ? "\(tangerine)▶\(reset)\(selectedRow) " : "  "
    let label = i == at ? "\(selectedRow)\(bold)\(cream)\(item.label)\(reset)\(selectedRow)" : item.label
    let left = "  " + mark + label
    let right = item.badge.isEmpty ? "" : item.badge + reset + (i == at ? selectedRow : "")
    row(pad(left, w - width(right) - 2) + right + "  ", highlight: i == at)
  }
  row("")
  row("  \(muted)\(list[at].hint)\(reset)")
  row("")
  rule("├", "┤")
  let keys = "  \(cream)↑↓\(reset) \(muted)move\(reset)   \(cream)⏎\(reset) \(muted)choose\(reset)   \(cream)q\(reset) \(muted)quit\(reset)"
  let link = "\(muted)github.com/saaquiblabs/lost-buttons\(reset)  "
  row(width(keys) + width(link) <= w ? pad(keys, w - width(link)) + link : keys)
  rule("╰", "╯")
  print(o, terminator: "")
  fflush(stdout)
}

func menu() {
  signal(SIGINT) { _ in
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
    print("\u{1B}[?25h\u{1B}[?1049l", terminator: "")
    exit(0)
  }
  screen(true)
  rawMode(true)
  defer { rawMode(false); screen(false) }

  var status = Status.now()
  var at = suggested(status)
  var lastSuggestion = at
  while true {
    let list = items(status)
    at = min(at, list.count - 1)
    draw(status, list, at: at)

    var chosen: Int?
    switch readKey(timeout: 1500) {
    case .none:  // nobody pressed anything: refresh, and follow the suggestion if it moved
      status = Status.now()
      let s = suggested(status)
      if s != lastSuggestion, at == lastSuggestion { at = s }
      lastSuggestion = s
      continue
    case .up: at = (at - 1 + list.count) % list.count
    case .down: at = (at + 1) % list.count
    case .enter: chosen = at
    case .digit(let d) where d <= list.count: chosen = d - 1
    case .quit: return
    default: break
    }
    guard let c = chosen else { continue }
    if c == list.count - 1 { return }
    list[c].action()
    status = Status.now()
    at = suggested(status)
    lastSuggestion = at
  }
}
