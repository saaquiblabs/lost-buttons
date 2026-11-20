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
    waiting: waiting.values.map { plainName(describe($0)) }.sorted())
  guard let data = try? JSONEncoder().encode(state) else { return }
  try? data.write(to: URL(fileURLWithPath: stateFile), options: .atomic)
}

func readState() -> ServiceState? {
  guard let data = FileManager.default.contents(atPath: stateFile) else { return nil }
  return try? JSONDecoder().decode(ServiceState.self, from: data)
}

private var askSource: DispatchSourceSignal?

/// The menu sends SIGUSR1 to get a fresh state (say, after Accessibility was just switched on).
func answerStateRequests() {
  signal(SIGUSR1, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
  source.setEventHandler { writeState() }
  source.resume()
  askSource = source
}
