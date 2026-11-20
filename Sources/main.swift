// Lost Buttons: makes the mouse buttons macOS drops work again.
//
// It only ever opens a mouse whose HID descriptor has unnamed button bits (see Descriptor.swift).
// Every other device is left alone. No polling, no network, no admin rights.
import AppKit
import IOKit
import IOKit.hid

let version = "0.1.0"

func log(_ s: String) { print(s); fflush(stdout) }

// MARK: - Sending the buttons on

/// Apps that ignore mouse buttons 4/5 entirely; they get Cmd+[ / Cmd+] (Back / Forward) instead.
let keyboardApps: Set<String> = [
  "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.finder",
  "com.apple.systempreferences", "com.apple.AppStore", "com.apple.Music",
  "com.apple.TV", "com.apple.Podcasts", "com.apple.Notes", "com.apple.helpviewer",
]

var warnedAboutAccessibility = false

/// Re-emits a button press. `button` is 1-based: 4 = Back, 5 = Forward.
func post(button: Int, down: Bool) {
  if !CGPreflightPostEventAccess(), !warnedAboutAccessibility {
    warnedAboutAccessibility = true
    CGRequestPostEventAccess()
    log("Needs Accessibility permission to send button presses: System Settings → Privacy & Security → Accessibility")
  }
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
    waitForInputMonitoring()
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
    DispatchQueue.main.async { fixed[id] = nil }  // free after this callback returns
  }, context)
  IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

  let buttons = runs.map { $0.count == 1 ? "\($0.firstButton)" : "\($0.firstButton)–\($0.firstButton + $0.count - 1)" }
  log("Fixing \(mouse.name): buttons \(buttons.joined(separator: ", "))")
}

/// Asks for Input Monitoring once, then checks every 5 s until granted. Only runs while an
/// affected mouse is plugged in and permission is missing; stops for good once granted.
func waitForInputMonitoring() {
  guard permissionTimer == nil else { return }
  IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
  log("Needs Input Monitoring permission to read the buttons: System Settings → Privacy & Security → Input Monitoring")
  permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
    guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
    timer.invalidate()
    permissionTimer = nil
    let services = waiting.values
    waiting = [:]
    for service in services { consider(service); IOObjectRelease(service) }
  }
}

func drain(_ iterator: io_iterator_t) {
  while case let service = IOIteratorNext(iterator), service != 0 {
    consider(service)
    IOObjectRelease(service)
  }
}

func run() {
  log("Lost Buttons \(version): watching for mice with hidden buttons")
  guard let port = IONotificationPortCreate(kIOMainPortDefault) else { log("IOKit unavailable"); exit(1) }
  CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
  var iterator: io_iterator_t = 0
  IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching(kIOHIDDeviceKey),
                                   { _, iterator in drain(iterator) }, nil, &iterator)
  drain(iterator)  // devices already connected; also arms the notification
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

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil: run()
case "doctor": doctor(raw: args.contains("--raw"))
case "--version", "-v": print(version)
case "--help", "-h", "help":
  print("""
  Lost Buttons \(version): makes the mouse buttons macOS drops work again.

  usage:
    lost-buttons                 run (normally started for you by `brew services start lost-buttons`)
    lost-buttons doctor [--raw]  check which connected mice have dropped buttons
    lost-buttons --version
  """)
default:
  FileHandle.standardError.write("unknown command: \(args[0]) (try --help)\n".data(using: .utf8)!)
  exit(2)
}
