// What the running copy tells the menu: which mice it fixes and which permissions it has. The menu
// can't check permissions itself: run from a terminal, macOS would answer for the terminal app.
// Written only when something changes (a mouse comes or goes, a permission arrives) or when the menu
// asks with SIGUSR1, so it costs nothing while idle.
import AppKit
import IOKit.hid

let stateFile = NSTemporaryDirectory() + "lost-buttons.state.json"

struct ServiceState: Codable {
  var pid: Int32
  var version: String
  var inputMonitoring: Bool
  var accessibility: Bool
  var fixing: [String]
  var waiting: [String]
  /// Restarts in a row while waiting for a permission (main.swift, waitForPermissions).
  var attempts: Int?
}

/// "K Chimera [248a:5b4a]" → "K Chimera"
func plainName(_ described: String) -> String {
  described.range(of: " [", options: .backwards).map { String(described[..<$0.lowerBound]) } ?? described
}

func writeState() {
  let state = ServiceState(
    pid: getpid(), version: version,
    inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
    accessibility: CGPreflightPostEventAccess(),
    fixing: fixed.values.map { plainName($0.name) }.sorted(),
    waiting: waiting.values.map { plainName(describe($0)) }.sorted(),
    attempts: attempts)
  guard let data = try? JSONEncoder().encode(state) else { return }
  try? data.write(to: URL(fileURLWithPath: stateFile), options: .atomic)
}

func readState() -> ServiceState? {
  guard let data = FileManager.default.contents(atPath: stateFile) else { return nil }
  return try? JSONDecoder().decode(ServiceState.self, from: data)
}

private var signalSources: [DispatchSourceSignal] = []

/// The menu sends SIGUSR1 to get a fresh state, and SIGUSR2 to check permissions again now
/// (after you switched one on), instead of at the next scheduled check.
func answerStateRequests() {
  for (sig, handler) in [(SIGUSR1, { writeState() }), (SIGUSR2, { recheckPermissions() })] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler(handler: handler)
    source.resume()
    signalSources.append(source)
  }
}
