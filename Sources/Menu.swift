// The menu `lost-buttons` shows when you run it yourself in a terminal.
//
// Full screen (the terminal's alternate screen, so your scrollback is left as it was). The real app
// icon at the top where the terminal can show images (Ghostty and kitty: the kitty graphics protocol;
// iTerm2 and WezTerm: iTerm2's inline images), a text header elsewhere. Live status from the running
// copy (State.swift), the next useful step already picked, arrow keys and Enter, r to check again.
// Redraws only when something changed. Keys and the overall shape follow ccstatusline's
// configuration menu (sirmalloc/ccstatusline, MIT). That one is built with Ink, a JavaScript
// library, so its code can't come along into a dependency-free Swift tool; this is termios and ANSI.
//
// Run by launchd (no terminal attached), `lost-buttons` does its job instead: run().
import AppKit
import IOKit
import IOKit.hid

let interactive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
let bundleID = "com.saaquiblabs.lost-buttons"

// MARK: - colours (24-bit; the icon's own tangerine and cream)

private let esc = "\u{1B}["
private func fg(_ r: Int, _ g: Int, _ b: Int) -> String { "\(esc)38;2;\(r);\(g);\(b)m" }
private func bg(_ r: Int, _ g: Int, _ b: Int) -> String { "\(esc)48;2;\(r);\(g);\(b)m" }
private let tangerine = fg(255, 122, 51), cream = fg(244, 235, 221), green = fg(95, 211, 138)
private let amber = fg(255, 196, 77), muted = fg(138, 145, 156), frameColour = fg(70, 76, 88)
private let bold = "\(esc)1m", reset = "\(esc)0m"
private let selectedBackground = bg(52, 40, 34)

// MARK: - what's going on

/// Is the background copy running? It holds the lock `run()` takes (isAlreadyRunning).
func backgroundRunning() -> Bool {
  let fd = open(NSTemporaryDirectory() + "lost-buttons.lock", O_CREAT | O_RDWR, 0o600)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
  return true
}

/// One mouse (or other button device) as the menu shows it. A device can appear as several HID
/// interfaces; they're merged by name, and it counts as affected if any interface is.
struct Device { let name: String; var affected: Bool; var buttons: String }

func devices() -> [Device] {
  var iterator: io_iterator_t = 0
  guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == KERN_SUCCESS
  else { return [] }
  defer { IOObjectRelease(iterator) }
  var found: [String: Device] = [:]
  while case let service = IOIteratorNext(iterator), service != 0 {
    defer { IOObjectRelease(service) }
    guard let bytes = descriptor(service), hasButtons(bytes) else { continue }
    let name = property(service, kIOHIDProductKey) as? String ?? "Unnamed device"
    let runs = findHiddenButtons(bytes)
    let buttons = runs.map { $0.count == 1 ? "button \($0.firstButton)" : "buttons \($0.firstButton)–\($0.firstButton + $0.count - 1)" }
      .joined(separator: ", ")
    var d = found[name] ?? Device(name: name, affected: false, buttons: "")
    if !runs.isEmpty { d.affected = true; d.buttons = buttons }
    found[name] = d
  }
  return found.values.sorted { ($0.affected ? 0 : 1, $0.name) < ($1.affected ? 0 : 1, $1.name) }
}

private struct Status {
  var running: Bool
  /// Not running for a moment because it quit to check permissions again; launchd brings it back.
  var restarting: Bool
  var state: ServiceState?
  var mice: [String]

  static func now() -> Status {
    let running = backgroundRunning()
    var state = readState()
    if running, let old = state {
      kill(old.pid, SIGUSR1)  // ask for a fresh one
      usleep(120_000)
      state = readState()
    }
    // Not running but still loaded: launchd is about to start it again (it quit to re-check
    // permissions). After `brew services stop` it's unloaded, so this is false.
    let restarting = !running && serviceLoaded()
    return Status(running: running, restarting: restarting, state: running || restarting ? state : nil,
                  mice: devices().filter(\.affected).map(\.name))
  }

  var inputMonitoring: Bool? { state?.inputMonitoring }
  var accessibility: Bool? { state?.accessibility }
  var needsInputMonitoring: Bool { inputMonitoring == false && !mice.isEmpty }
  var needsAccessibility: Bool { accessibility == false && !mice.isEmpty }
}

/// Is Homebrew's service loaded in launchd (started, even if between two runs)?
func serviceLoaded() -> Bool {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
  p.arguments = ["print", "gui/\(getuid())/sh.brew.lost-buttons"]
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  guard (try? p.run()) != nil else { return false }
  p.waitUntilExit()
  return p.terminationStatus == 0
}

// MARK: - terminal

private var savedTermios = termios()

private func rawMode(_ on: Bool) {
  if on {
    tcgetattr(STDIN_FILENO, &savedTermios)
    var raw = savedTermios
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
  } else {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
  }
}

private func write(_ s: String) {
  print(s, terminator: "")
  fflush(stdout)
}

private func terminalSize() -> (cols: Int, rows: Int) {
  var w = winsize()
  guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0 else { return (80, 24) }
  return (Int(w.ws_col), Int(w.ws_row))
}

private enum Key { case up, down, enter, quit, refresh, digit(Int), none, other }

/// Waits up to `timeout` ms for a key; .none when nothing came (time to refresh) or the window
/// was resized (SIGWINCH interrupts the wait).
private func readKey(timeout: Int32) -> Key {
  var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
  guard poll(&fds, 1, timeout) > 0 else { return .none }
  var c: UInt8 = 0
  guard read(STDIN_FILENO, &c, 1) == 1 else { return .quit }
  switch c {
  case 0x1B:  // Esc alone quits; Esc [ A / Esc [ B (or Esc O A / B) are the arrows
    var seq = [UInt8](repeating: 0, count: 2)
    var more = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&more, 1, 30) > 0, read(STDIN_FILENO, &seq, 2) == 2, seq[0] == 0x5B || seq[0] == 0x4F
    else { return .quit }
    return seq[1] == 0x41 ? .up : seq[1] == 0x42 ? .down : .other
  case 0x0A, 0x0D: return .enter
  case UInt8(ascii: "k"): return .up
  case UInt8(ascii: "j"): return .down
  case UInt8(ascii: "q"), UInt8(ascii: "Q"): return .quit
  case UInt8(ascii: "r"), UInt8(ascii: "R"): return .refresh
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

/// Cut to `to` visible characters, keeping colour codes; "…" marks a cut.
private func fit(_ s: String, _ to: Int) -> String {
  guard width(s) > to else { return s + String(repeating: " ", count: to - width(s)) }
  var out = "", n = 0, inCode = false
  for ch in s.unicodeScalars {
    if inCode { out.unicodeScalars.append(ch); if ch == "m" { inCode = false }; continue }
    if ch == "\u{1B}" { inCode = true; out.unicodeScalars.append(ch); continue }
    if n == to - 1 { break }
    out.unicodeScalars.append(ch)
    n += 1
  }
  return out + "…" + reset
}

/// Plain text broken into lines of at most `to` characters, at spaces.
private func wrap(_ s: String, _ to: Int) -> [String] {
  var lines: [String] = [], current = ""
  for word in s.split(separator: " ") {
    if !current.isEmpty && current.count + 1 + word.count > to { lines.append(current); current = "" }
    current += (current.isEmpty ? "" : " ") + word
  }
  return current.isEmpty ? lines : lines + [current]
}

// MARK: - the icon

private enum ImageProtocol { case kitty, iterm }

/// Which way this terminal can show a picture, if any. Not inside tmux or screen, which pass
/// neither through by default.
private let imageProtocol: ImageProtocol? = {
  let env = ProcessInfo.processInfo.environment
  if env["TMUX"] != nil || env["TERM"]?.hasPrefix("screen") == true { return nil }
  switch env["TERM_PROGRAM"] {
  case "ghostty": return .kitty
  case "iTerm.app", "WezTerm": return .iterm
  default: return env["TERM"] == "xterm-kitty" ? .kitty : nil
  }
}()

/// The app icon as PNG data, its transparent margin trimmed, from the app bundle.
private let iconPNG: Data? = {
  guard imageProtocol != nil,
        let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
        let image = NSImage(contentsOf: url) else { return nil }
  let size = 160
  guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  let trim = Double(size) * 0.05
  image.draw(in: NSRect(x: -trim, y: -trim, width: Double(size) + 2 * trim, height: Double(size) + 2 * trim))
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])
}()

private let iconCols = 12, iconRows = 6, kittyImageID = 7351

/// kitty: send the picture once; each redraw only places it (cheap, no flicker).
private func sendIcon() {
  guard imageProtocol == .kitty, let png = iconPNG else { return }
  let b64 = png.base64EncodedString()
  var chunks: [Substring] = []
  var i = b64.startIndex
  while i < b64.endIndex {
    let j = b64.index(i, offsetBy: 4096, limitedBy: b64.endIndex) ?? b64.endIndex
    chunks.append(b64[i..<j])
    i = j
  }
  for (n, chunk) in chunks.enumerated() {
    let more = n < chunks.count - 1 ? 1 : 0
    let head = n == 0 ? "a=t,f=100,i=\(kittyImageID),q=2,m=\(more)" : "m=\(more)"
    write("\u{1B}_G\(head);\(chunk)\u{1B}\\")
  }
}

/// Puts the icon at a screen position (1-based), leaving the cursor where it was.
private func placeIcon(row: Int, col: Int) -> String {
  guard let png = iconPNG else { return "" }
  let at = "\u{1B}7\(esc)\(row);\(col)H"
  switch imageProtocol {
  case .kitty: return at + "\u{1B}_Ga=p,i=\(kittyImageID),p=1,c=\(iconCols),r=\(iconRows),C=1,q=2\u{1B}\\\u{1B}8"
  case .iterm:
    return at + "\u{1B}]1337;File=inline=1;width=\(iconCols);height=\(iconRows);preserveAspectRatio=1:"
      + png.base64EncodedString() + "\u{07}\u{1B}8"
  case nil: return ""
  }
}

private func removeIcon() {
  if imageProtocol == .kitty { write("\u{1B}_Ga=d,d=I,i=\(kittyImageID),q=2\u{1B}\\") }
}

// MARK: - drawing

/// A framed screen: header, then sections split by rules, then the key line. Drawn over the
/// previous one in place; only sent when it differs.
private var lastFrame = ""

private func render(sections: [[String]], keys: String, force: Bool = false) {
  let size = terminalSize()
  let w = max(30, min(72, size.cols - 4))  // inner width
  let showIcon = iconPNG != nil && w >= 56 && size.rows >= 30
  let compact = size.rows < 30

  var lines: [String] = []
  func row(_ text: String) { lines.append("  \(frameColour)│\(reset)" + fit(text, w) + "\(reset)\(frameColour)│\(reset)") }
  func rule(_ l: String, _ r: String) { lines.append("  \(frameColour)\(l)" + String(repeating: "─", count: w) + "\(r)\(reset)") }

  rule("╭", "╮")
  let name = "\(tangerine)\(bold)Lost Buttons\(reset)  \(muted)v\(version)\(reset)"
  let tagline = "\(cream)Your mouse's side buttons, back on the Mac.\(reset)"
  let credit = "\(muted)Free and open source · by Saaquib Labs\(reset)"
  if showIcon {
    let indent = String(repeating: " ", count: 3 + iconCols + 3)
    for t in ["", "", name, tagline, "", credit] { row(indent + t) }
    row("")
  } else if compact {
    row("  " + name + "   " + tagline)
  } else {
    row("")
    row("  " + name)
    row("  " + tagline)
    row("  " + credit)
    row("")
  }
  for section in sections {
    rule("├", "┤")
    if !compact { row("") }
    for l in section where !(compact && l.isEmpty) { row(l) }
    if !compact { row("") }
  }
  rule("├", "┤")
  let link = "\(muted)github.com/saaquiblabs/lost-buttons\(reset)  "
  row(width(keys) + width(link) <= w ? keys + String(repeating: " ", count: w - width(keys) - width(link)) + link : keys)
  rule("╰", "╯")

  var frame = "\(esc)H" + (compact ? "" : "\n") + lines.joined(separator: "\(esc)K\n") + "\(esc)K\(esc)J"
  if showIcon { frame += placeIcon(row: compact ? 2 : 3 + 1, col: 3 + 1 + 3) }
  guard force || frame != lastFrame else { return }
  if force { write("\(esc)2J") }
  lastFrame = frame
  write(frame)
}

private func keyLine(_ parts: [(String, String)]) -> String {
  "  " + parts.map { "\(cream)\($0.0)\(reset) \(muted)\($0.1)\(reset)" }.joined(separator: "   ")
}

/// A message screen in the same frame; any key goes back.
private func showMessage(_ title: String, _ body: [String]) {
  render(sections: [["  \(bold)\(title)\(reset)", ""] + body], keys: keyLine([("any key", "back")]), force: true)
  while case .none = readKey(timeout: 60_000) {}
  lastFrame = ""
}

// MARK: - actions

/// Runs a shell command and returns whether it worked, and what it printed.
@discardableResult
private func shell(_ command: String) -> (ok: Bool, output: String) {
  let p = Process(), out = Pipe()
  p.executableURL = URL(fileURLWithPath: "/bin/zsh")
  p.arguments = ["-lc", command]  // -l: the login PATH, so Homebrew's `brew` is found
  p.standardOutput = out
  p.standardError = out
  guard (try? p.run()) != nil else { return (false, "") }
  let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  p.waitUntilExit()
  return (p.terminationStatus == 0, text)
}

private func brewService(_ verb: String) {
  guard shell("command -v brew").ok else {
    showMessage("Homebrew isn't installed", [
      "  Lost Buttons runs in the background through Homebrew.",
      "  Get Homebrew from brew.sh, then: brew install saaquiblabs/tap/lost-buttons",
      "  Or run it in this terminal with: lost-buttons run",
    ])
    return
  }
  let r = shell("brew services \(verb) lost-buttons")
  if !r.ok {
    showMessage("That didn't work", r.output.split(separator: "\n").map { "  \(muted)\($0)\(reset)" })
    return
  }
  // Give launchd a moment, so the status that follows is the new one.
  for _ in 0..<12 where backgroundRunning() != (verb != "stop") { usleep(250_000) }
}

private func openSettings(_ pane: String) {
  NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
}

/// Where the app is. Homebrew's fixed path when installed with it, so the address stays the same
/// across upgrades; otherwise wherever this copy runs from.
private func appURL() -> URL {
  let brew = URL(fileURLWithPath: "/opt/homebrew/opt/lost-buttons/Lost Buttons.app")
  let intel = URL(fileURLWithPath: "/usr/local/opt/lost-buttons/Lost Buttons.app")
  for u in [brew, intel] where FileManager.default.fileExists(atPath: u.path) { return u }
  return Bundle.main.bundleURL
}

private func showApp() {
  NSWorkspace.shared.activateFileViewerSelecting([appURL()])
  showMessage("Finder is showing Lost Buttons", [
    "  If Lost Buttons is missing from Input Monitoring or Accessibility,",
    "  drag it from Finder into that list (or click +, then pick it).",
    "",
    "  \(muted)Leave it where it is: Homebrew keeps it in this folder.\(reset)",
    "  \(muted)\(appURL().path)\(reset)",
  ])
}

/// Forgets every Lost Buttons entry in both lists (old builds leave their own, under the same
/// name, and a switch can belong to an old one), restarts it, so macOS asks again for this build.
private func fixPermissions(_ s: Status) {
  LSRegisterURL(appURL() as CFURL, true)  // tccutil only knows bundle IDs macOS has registered
  for service in ["ListenEvent", "Accessibility"] { shell("tccutil reset \(service) \(bundleID)") }
  brewService("restart")  // also starts it if it was stopped: a running copy is what asks
  showMessage("Permissions reset", [
    "  macOS has forgotten every Lost Buttons entry, old ones included.",
    "",
    "  1. With your mouse plugged in, macOS asks for Input Monitoring in a",
    "     moment. Click Open System Settings and switch on Lost Buttons.",
    "  2. Then the same for Accessibility.",
    "",
    "  \(muted)Missed a prompt? Use Allow Input Monitoring / Allow Accessibility,\(reset)",
    "  \(muted)and Show the app in Finder if Lost Buttons isn't in the list.\(reset)",
  ])
}

private func showMice() {
  let all = devices()
  var body: [String] = []
  if all.isEmpty { body.append("  \(muted)No mouse found. Plug it in, then press r.\(reset)") }
  for d in all {
    if d.affected {
      body.append("  \(amber)●\(reset) \(bold)\(d.name)\(reset)")
      body.append("    \(muted)macOS drops \(d.buttons). Lost Buttons brings them back.\(reset)")
    } else {
      body.append("  \(green)✓\(reset) \(d.name)")
      body.append("    \(muted)Every button works. Nothing to fix.\(reset)")
    }
  }
  let n = all.filter(\.affected).count
  body += ["", n == 0
    ? "  Nothing for Lost Buttons to do right now."
    : "  Lost Buttons fixes \(n) of these."]
  showMessage("Your mice", body)
}

// MARK: - the menu

private struct Item {
  let label: String
  let badge: String  // right-hand note: "needed", "✓ allowed", "fixes K Chimera"
  let hint: String
  let action: (Status) -> Void
}

private func items(_ s: Status) -> [Item] {
  func badge(_ v: Bool?) -> String { v.map { $0 ? "\(green)✓ allowed" : "\(amber)needed" } ?? "" }
  let notListed = " Not in the list? Use Show the app in Finder."
  return [
    s.running || s.restarting
      ? Item(label: "Stop Lost Buttons", badge: "", hint: "Stops it now and at every login. Your side buttons stop working.",
             action: { _ in brewService("stop") })
      : Item(label: "Start Lost Buttons", badge: s.mice.isEmpty ? "" : "\(tangerine)fixes \(s.mice.joined(separator: ", "))",
             hint: "Runs it in the background, now and at every login.",
             action: { _ in brewService("start") }),
    Item(label: "Allow Input Monitoring", badge: badge(s.inputMonitoring),
         hint: "Opens the setting: switch on Lost Buttons (it reads the hidden buttons). Then press r." + notListed,
         action: { _ in openSettings("Privacy_ListenEvent") }),
    Item(label: "Allow Accessibility", badge: badge(s.accessibility),
         hint: "Opens the setting: switch on Lost Buttons (it sends Back and Forward to apps). Then press r." + notListed,
         action: { _ in openSettings("Privacy_Accessibility") }),
    Item(label: "Check my mice", badge: "", hint: "Every connected mouse, and whether macOS drops any of its buttons.",
         action: { _ in showMice() }),
    Item(label: "Show the app in Finder", badge: "", hint: "Homebrew keeps the app in a hidden folder. This shows it.",
         action: { _ in showApp() }),
    Item(label: "Fix permissions", badge: "",
         hint: "Switched both on and it still says needed? This clears old entries so macOS asks again.",
         action: { s in fixPermissions(s) }),
    Item(label: "Quit", badge: "", hint: "Closes this menu. Lost Buttons keeps running in the background.",
         action: { _ in }),
  ]
}

/// The most useful item for the state things are in.
private func suggested(_ s: Status) -> Int {
  if !s.running && !s.restarting { return 0 }
  if s.needsInputMonitoring { return 1 }
  if s.needsAccessibility { return 2 }
  return 7
}

private func statusLines(_ s: Status, checking: Bool) -> [String] {
  var out = ["  \(muted)STATUS\(reset)"]
  if s.restarting || checking && !s.running {
    out.append("  \(amber)●\(reset) Checking permissions again…")
  } else if s.running {
    out.append("  \(green)●\(reset) Running in the background")
  } else {
    out.append("  \(muted)○\(reset) Not running")
  }
  if s.mice.isEmpty { out.append("  \(muted)○ No mouse with dropped buttons is plugged in.\(reset)") }
  for m in s.mice {
    let mouse = "\(bold)\(m)\(reset)"
    if !s.running && !s.restarting {
      out.append("  \(amber)●\(reset) \(mouse)  side buttons off. Start Lost Buttons to fix them.")
    } else if s.state == nil {
      out.append("  \(muted)●\(reset) \(mouse)  \(muted)restart Lost Buttons to see its status\(reset)")
    } else if s.needsInputMonitoring {
      out.append("  \(amber)●\(reset) \(mouse)  waiting for Input Monitoring")
    } else if s.needsAccessibility {
      out.append("  \(amber)●\(reset) \(mouse)  waiting for Accessibility")
    } else if s.state?.fixing.contains(m) == true {
      out.append("  \(green)●\(reset) \(mouse)  Back and Forward work")
    } else {
      out.append("  \(amber)●\(reset) \(mouse)  connecting…")
    }
  }
  return out
}

private func restoreTerminal() {
  removeIcon()
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
  write("\(esc)0m\(esc)?25h\(esc)?1049l")
}

func menu() {
  for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
      if imageProtocol == .kitty { print("\u{1B}_Ga=d,d=I,i=7351,q=2\u{1B}\\", terminator: "") }
      tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
      print("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l", terminator: "")
      fflush(stdout)
      exit(0)
    }
  }
  signal(SIGWINCH) { _ in }  // interrupts the wait, so a resized window is redrawn at once
  write("\(esc)?1049h\(esc)?25l")  // alternate screen, no cursor
  rawMode(true)
  defer { restoreTerminal() }
  sendIcon()

  var status = Status.now()
  var at = suggested(status)
  var lastSuggestion = at
  var checkingUntil = Date.distantPast
  var size = terminalSize()
  while true {
    let list = items(status)
    at = min(at, list.count - 1)
    let checking = Date() < checkingUntil
    let w = max(30, min(72, terminalSize().cols - 4))
    let menuLines = list.enumerated().map { i, item -> String in
      let on = i == at ? selectedBackground : ""
      let left = i == at ? "  \(tangerine)▶\(reset)\(on) \(bold)\(cream)\(item.label)\(reset)" : "    \(item.label)"
      let right = item.badge.isEmpty ? "" : item.badge + reset
      let gap = max(1, w - width(left) - width(right) - 2)
      return on + left + on + String(repeating: " ", count: gap) + right + on + "  "
    }
    let hint = (checking ? ["  \(amber)Checking again…\(reset)"] : [])
      + wrap(list[at].hint, w - 4).map { "  \(muted)\($0)\(reset)" }
    let newSize = terminalSize()
    render(sections: [statusLines(status, checking: checking), menuLines + [""] + hint],
           keys: keyLine([("↑↓", "move"), ("⏎", "choose"), ("r", "check again"), ("q", "quit")]),
           force: newSize != size)
    size = newSize

    var chosen: Int?
    switch readKey(timeout: 1500) {
    case .none:  // nothing pressed: refresh, and follow the suggestion if the user hadn't moved
      status = Status.now()
      let s = suggested(status)
      if s != lastSuggestion, at == lastSuggestion { at = s }
      lastSuggestion = s
      continue
    case .refresh:
      if let pid = status.state?.pid, status.running { kill(pid, SIGUSR2) }  // check permissions now
      checkingUntil = Date().addingTimeInterval(4)
      status = Status.now()
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
    list[c].action(status)
    lastFrame = ""
    status = Status.now()
    at = suggested(status)
    lastSuggestion = at
  }
}
