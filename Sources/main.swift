// Lost Buttons: makes the mouse buttons macOS drops work again.
//
// It only ever opens a mouse whose HID descriptor has unnamed button bits (see Descriptor.swift).
// Every other device is left alone. No polling, no network, no admin rights.
import AppKit
import IOKit
import IOKit.hid

let version = "0.4.4"

func log(_ s: String) { print(s); fflush(stdout) }

// MARK: - Sending the buttons on

/// Apps that ignore mouse buttons 4/5 entirely; they get Cmd+[ / Cmd+] (Back / Forward) instead.
let keyboardApps: Set<String> = [
  "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.finder",
  "com.apple.systempreferences", "com.apple.AppStore", "com.apple.Music",
  "com.apple.TV", "com.apple.Podcasts", "com.apple.Notes", "com.apple.helpviewer",
]

/// Re-emits a button press. `button` is 1-based: 4 = Back, 5 = Forward.
func post(button: Int, down: Bool) {
  let source = CGEventSource(stateID: .hidSystemState)
  let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
  if button == 4 || button == 5, keyboardApps.contains(app) {
    guard down else { return }
    let key: CGKeyCode = button == 4 ? 33 : 30  // [ or ]
    for isDown in [true, false] {
      let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
      e?.flags = .maskCommand
      e?.post(tap: .cghidEventTap)
    }
    return
  }
  let index = Int64(button - 1)  // CoreGraphics numbers buttons from 0
  guard let cgButton = CGMouseButton(rawValue: UInt32(index)) else { return }
  let location = CGEvent(source: nil)?.location ?? .zero
  let e = CGEvent(mouseEventSource: source, mouseType: down ? .otherMouseDown : .otherMouseUp,
                  mouseCursorPosition: location, mouseButton: cgButton)
  e?.setIntegerValueField(.mouseEventButtonNumber, value: index)
  e?.post(tap: .cghidEventTap)
}

// MARK: - One fixed mouse

final class FixedMouse {
  let id: UInt64
  let name: String
  let device: IOHIDDevice
  let runs: [HiddenButtons]
  let buffer: UnsafeMutablePointer<UInt8>
  let bufferSize: Int
  var previous: [UInt64]

  init(id: UInt64, name: String, device: IOHIDDevice, runs: [HiddenButtons], bufferSize: Int) {
    self.id = id; self.name = name; self.device = device; self.runs = runs
    self.bufferSize = bufferSize
    buffer = .allocate(capacity: bufferSize)
    previous = Array(repeating: 0, count: runs.count)
  }
  deinit { buffer.deallocate() }

  func handle(reportID: UInt8, report: UnsafeMutablePointer<UInt8>, length: Int) {
    for (n, run) in runs.enumerated() where run.reportID == reportID {
      let base = run.reportID == 0 ? 0 : 1  // skip the report ID byte
      var bits: UInt64 = 0
      for k in 0..<min(run.count, 64) {
        let bit = run.bitOffset + k
        let byte = base + bit / 8
        guard byte < length else { break }
        if (report[byte] >> UInt8(bit % 8)) & 1 == 1 { bits |= 1 << UInt64(k) }
      }
      let changed = bits ^ previous[n]
      guard changed != 0 else { continue }
      previous[n] = bits
      for k in 0..<min(run.count, 64) where (changed >> UInt64(k)) & 1 == 1 {
        post(button: run.firstButton + k, down: (bits >> UInt64(k)) & 1 == 1)
      }
    }
  }
}

var fixed: [UInt64: FixedMouse] = [:]
var waiting: [UInt64: io_service_t] = [:]  // affected mice waiting for Input Monitoring
var permissionTimer: Timer?

func property(_ service: io_service_t, _ key: String) -> Any? {
  IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func describe(_ service: io_service_t) -> String {
  let name = property(service, kIOHIDProductKey) as? String ?? "Unnamed device"
  let vendor = property(service, kIOHIDVendorIDKey) as? Int ?? 0
  let product = property(service, kIOHIDProductIDKey) as? Int ?? 0
  return "\(name) [\(String(format: "%04x:%04x", vendor, product))]"
}

func descriptor(_ service: io_service_t) -> [UInt8]? {
  (property(service, kIOHIDReportDescriptorKey) as? Data).map { [UInt8]($0) }
}

/// Called for every HID device that appears. Opens it only if it has hidden buttons.
func consider(_ service: io_service_t) {
  guard let bytes = descriptor(service) else { return }
  let runs = findHiddenButtons(bytes)
  guard !runs.isEmpty else { return }
  var id: UInt64 = 0
  IORegistryEntryGetRegistryEntryID(service, &id)
  guard fixed[id] == nil else { return }

  guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
    if waiting[id] == nil { IOObjectRetain(service); waiting[id] = service }
    if !askedForInputMonitoring {
      askedForInputMonitoring = true
      IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)  // macOS shows its prompt once per build
      if attempts == 0 {
        log("Needs Input Monitoring permission to read the buttons: System Settings → Privacy & Security → Input Monitoring")
      }
    }
    writeState()
    waitForPermissions()
    return
  }
  guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return }
  let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
  guard result == kIOReturnSuccess else {
    log("Could not open \(describe(service)): " + String(format: "0x%x", result))
    return
  }
  let size = max(property(service, kIOHIDMaxInputReportSizeKey) as? Int ?? 64, 8)
  let mouse = FixedMouse(id: id, name: describe(service), device: device, runs: runs, bufferSize: size)
  fixed[id] = mouse
  let context = Unmanaged.passUnretained(mouse).toOpaque()

  IOHIDDeviceRegisterInputReportCallback(device, mouse.buffer, size, { context, _, _, _, reportID, report, length in
    guard let context else { return }
    Unmanaged<FixedMouse>.fromOpaque(context).takeUnretainedValue()
      .handle(reportID: UInt8(truncatingIfNeeded: reportID), report: report, length: length)
  }, context)
  IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
    guard let context else { return }
    let mouse = Unmanaged<FixedMouse>.fromOpaque(context).takeUnretainedValue()
    log("Disconnected: \(mouse.name)")
    IOHIDDeviceUnscheduleFromRunLoop(mouse.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    let id = mouse.id
    DispatchQueue.main.async { fixed[id] = nil; writeState() }  // free after this callback returns
  }, context)
  IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

  let buttons = runs.map { $0.count == 1 ? "\($0.firstButton)" : "\($0.firstButton)–\($0.firstButton + $0.count - 1)" }
  log("Fixing \(mouse.name): buttons \(buttons.joined(separator: ", "))")
  // Ask for Accessibility now, not at the first press, so Lost Buttons is already in that list.
  if !CGPreflightPostEventAccess() {
    if !askedForAccessibility {
      askedForAccessibility = true
      CGRequestPostEventAccess()
      if attempts == 0 {
        log("Needs Accessibility permission to send button presses: System Settings → Privacy & Security → Accessibility")
      }
    }
    waitForPermissions()
  }
  if !needsPermission() { attempts = 0 }
  writeState()
}

// MARK: - waiting for permissions

/// Under launchd (Homebrew's service) quitting means a restart: the service has KeepAlive.
let underLaunchd = getppid() == 1
var askedForInputMonitoring = false
var askedForAccessibility = false
/// Restarts in a row while waiting for a permission; carried over in the state file.
var attempts = 0

func needsPermission() -> Bool {
  !waiting.isEmpty || (!fixed.isEmpty && !CGPreflightPostEventAccess())
}

/// macOS answers a running process from what it knew when that process started: switching a
/// permission on later isn't seen. (Found 2026-11-21: the service kept getting "denied" for minutes
/// after the owner switched Input Monitoring on; a restart saw it at once.) So while an affected
/// mouse waits for a permission, the service quits after a pause and launchd starts a fresh copy:
/// after 5 s, then 10, 20, and every 30 s at most. Costs nothing once permissions are in, or while
/// no affected mouse is plugged in. The menu's "check again" (SIGUSR2) does it right away.
func waitForPermissions() {
  guard permissionTimer == nil else { return }
  let delay = min(30, 5 * pow(2.0, Double(attempts)))
  permissionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in recheckPermissions() }
}

func recheckPermissions() {
  permissionTimer?.invalidate()
  permissionTimer = nil
  if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted, !waiting.isEmpty {
    let services = waiting.values
    waiting = [:]
    for service in services { consider(service); IOObjectRelease(service) }
  }
  guard needsPermission() else { attempts = 0; writeState(); return }
  if underLaunchd {
    attempts += 1
    writeState()
    exit(0)  // launchd starts a fresh copy, which gets macOS's current answer
  }
  waitForPermissions()  // run by hand in a terminal: keep looking; restart it if it never sees the change
}

func drain(_ iterator: io_iterator_t) {
  while case let service = IOIteratorNext(iterator), service != 0 {
    consider(service)
    IOObjectRelease(service)
  }
}

/// Only one copy may run, or every press would be sent twice (say, the brew service plus a
/// double-clicked app). The lock is a per-user temp file; macOS releases it when we exit.
func isAlreadyRunning() -> Bool {
  let fd = open(NSTemporaryDirectory() + "lost-buttons.lock", O_CREAT | O_RDWR, 0o600)
  return fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0
}

/// Homebrew keeps the app outside /Applications, where macOS doesn't register apps by itself.
/// Unregistered, the permission prompts and Login Items show a gear and "lost-buttons" instead
/// of our name and icon. Registering is quick and harmless to repeat, so do it at every start.
func registerAppBundle() {
  let url = Bundle.main.bundleURL
  guard url.pathExtension == "app" else { return }
  LSRegisterURL(url as CFURL, true)
}

func run() {
  if isAlreadyRunning() { log("Lost Buttons is already running."); exit(0) }
  // Restarted while waiting for a permission? Then carry on counting, and don't log it all again.
  if let last = readState(), last.version == version, !last.waiting.isEmpty || !last.accessibility {
    attempts = last.attempts ?? 0
  }
  registerAppBundle()
  if attempts == 0 { log("Lost Buttons \(version): watching for mice with hidden buttons") }
  guard let port = IONotificationPortCreate(kIOMainPortDefault) else { log("IOKit unavailable"); exit(1) }
  CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
  var iterator: io_iterator_t = 0
  IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching(kIOHIDDeviceKey),
                                   { _, iterator in drain(iterator) }, nil, &iterator)
  drain(iterator)  // devices already connected; also arms the notification
  answerStateRequests()
  writeState()
  CFRunLoopRun()
}

// MARK: - doctor

func doctor(raw: Bool) {
  var iterator: io_iterator_t = 0
  guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == KERN_SUCCESS
  else { log("Could not list HID devices"); exit(1) }
  defer { IOObjectRelease(iterator) }
  var seen = 0, fixable = 0
  while case let service = IOIteratorNext(iterator), service != 0 {
    defer { IOObjectRelease(service) }
    guard let bytes = descriptor(service), hasButtons(bytes) else { continue }
    seen += 1
    let transport = property(service, kIOHIDTransportKey) as? String ?? "?"
    print("• \(describe(service)) via \(transport)")
    let runs = findHiddenButtons(bytes)
    if runs.isEmpty {
      print("    OK: macOS sees every button it declares. Nothing to fix.")
    } else {
      fixable += 1
      for r in runs {
        let span = r.count == 1 ? "button \(r.firstButton)" : "buttons \(r.firstButton)–\(r.firstButton + r.count - 1)"
        print("    Fixable: \(span) are sent but never named, so macOS drops them. Lost Buttons delivers them.")
      }
    }
    if raw { print("    descriptor: " + bytes.map { String(format: "%02x", $0) }.joined()) }
  }
  if seen == 0 { print("No mouse or other button device found. Plug it in and run again.") }
  print("")
  print(fixable > 0
    ? "Lost Buttons will fix \(fixable) device\(fixable == 1 ? "" : "s") above."
    : "Nothing for Lost Buttons to do on this Mac right now. If a button still does nothing,\n"
      + "run `lost-buttons doctor --raw` and open an issue with the output:\n"
      + "https://github.com/saaquiblabs/lost-buttons/issues")
}

// MARK: - main

func printHelp() {
  print("""
  Lost Buttons \(version): makes the mouse buttons macOS drops work again.

  usage:
    lost-buttons                 a menu: start or stop, permissions, check your mice
    lost-buttons doctor [--raw]  check which connected mice have dropped buttons
    lost-buttons run             run in the foreground (`brew services start lost-buttons` does this)
    lost-buttons --version
  """)
}

/// Double-clicked in Finder: LaunchServices names the job after our bundle ID.
let openedFromFinder = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?
  .hasPrefix("application.com.saaquiblabs.lost-buttons") ?? false

/// The app has no window of its own; opened from Finder, it shows the menu in Terminal.
func openMenuInTerminal() {
  guard let me = Bundle.main.executablePath else { exit(1) }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  p.arguments = ["-a", "Terminal", me]
  try? p.run()
  p.waitUntilExit()
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil where interactive: menu()
case nil where openedFromFinder: openMenuInTerminal()
case let a? where a.hasPrefix("-psn_"): openMenuInTerminal()  // older macOS adds this, from Finder
case nil where underLaunchd, "run": run()  // no argument: the 0.2–0.4.0 service plist
case nil: printHelp()
case "doctor": doctor(raw: args.contains("--raw"))
case "--version", "-v": print(version)
case "--help", "-h", "help": printHelp()
default:
  FileHandle.standardError.write("unknown command: \(args[0]) (try --help)\n".data(using: .utf8)!)
  exit(2)
}
