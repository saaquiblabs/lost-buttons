// Starting and stopping Lost Buttons as a background item that macOS shows under its own name and
// icon (System Settings → General → Login Items → Allow in the Background).
//
// Uses Apple's SMAppService with a launch agent plist inside the app
// (Contents/Library/LaunchAgents). Registration logic ported from Karabiner-Elements'
// ServiceManagementHelper.swift (pqrs-org/Karabiner-Elements, The Unlicense):
// retry while macOS has not yet noticed a newly installed app, and clear a stale
// record before registering.
import Foundation
import ServiceManagement

let agentPlist = "com.saaquiblabs.lost-buttons.plist"
let agent = SMAppService.agent(plistName: agentPlist)

/// The Homebrew service from 0.1/0.2. Two copies would fight over the mouse, so `start` stops it
/// first, the same way `brew services stop` does (bootout, then delete the plist).
let oldBrewService = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/LaunchAgents/sh.brew.lost-buttons.plist")

func describe(_ status: SMAppService.Status) -> String {
  switch status {
  case .enabled:
    return processRunning()
      ? "running in the background, and starts at every login"
      : "switched on, but macOS stopped it from launching. This happens when there is another copy\n"
        + "of Lost Buttons.app with the same version (for example one you built yourself). Delete the\n"
        + "other copy, then run `lost-buttons start` again."
  case .requiresApproval:
    return "registered, but switched off in System Settings → General → Login Items & Extensions → "
      + "Allow in the Background. Switch Lost Buttons on there."
  case .notRegistered: return "not started (run `lost-buttons start`)"
  case .notFound: return "not started (run `lost-buttons start`)"
  @unknown default: return "unknown (\(status.rawValue))"
  }
}

func registered(_ status: SMAppService.Status) -> Bool {
  status == .enabled || status == .requiresApproval
}

func startService() -> Int32 {
  guard Bundle.main.bundleURL.pathExtension == "app" else {
    log("Run this from Lost Buttons.app (`lost-buttons start` after a Homebrew install).")
    return 1
  }
  if FileManager.default.fileExists(atPath: oldBrewService.path) {
    launchctl(["bootout", "gui/\(getuid())/sh.brew.lost-buttons"])
    try? FileManager.default.removeItem(at: oldBrewService)
    log("Stopped the Homebrew service from Lost Buttons 0.2; it starts the new way from now on.")
  }
  registerAppBundle()
  // Every build is signed ad hoc, so each upgrade has a new signature, and macOS kills a login item
  // whose signature differs from the one it recorded (OS_REASON_CODESIGNING). Registering afresh
  // records this build's, and also replaces a copy still running from the old version.
  if registered(agent.status) || agent.status == .notFound {
    try? agent.unregister()  // also clears a stale record; harmless if none
    // Asynchronous: wait (up to 5 s) for launchd to drop the old job.
    let label = "gui/\(getuid())/com.saaquiblabs.lost-buttons"
    for _ in 0..<20 where launchctl(["print", label]) == 0 { Thread.sleep(forTimeInterval: 0.25) }
  }
  // macOS may not see a freshly installed app at once (.notFound); retry for up to 10 s.
  for _ in 0..<10 {
    do { try agent.register() } catch { log("Could not start: \(error.localizedDescription)") }
    if agent.status != .notFound { break }
    Thread.sleep(forTimeInterval: 1)
  }
  if agent.status == .enabled {  // give launchd a moment, so the status line is the truth
    for _ in 0..<12 where !processRunning() { Thread.sleep(forTimeInterval: 0.25) }
  }
  log("Lost Buttons is \(describe(agent.status))")
  if agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
  return registered(agent.status) ? 0 : 1
}

@discardableResult
func launchctl(_ args: [String]) -> Int32 {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
  p.arguments = args
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  guard (try? p.run()) != nil else { return -1 }
  p.waitUntilExit()
  return p.terminationStatus
}

/// Is a copy running? It holds the lock `run()` takes (isAlreadyRunning in main.swift).
func processRunning() -> Bool {
  let fd = open(NSTemporaryDirectory() + "lost-buttons.lock", O_CREAT | O_RDWR, 0o600)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
  return true
}

func stopService() -> Int32 {
  do { try agent.unregister() } catch { log("Could not stop: \(error.localizedDescription)") }
  log("Lost Buttons is \(describe(agent.status))")
  return registered(agent.status) ? 1 : 0
}

func printStatus() {
  log("Lost Buttons \(version) is \(describe(agent.status))")
}
