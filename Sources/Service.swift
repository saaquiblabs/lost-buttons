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

/// The Homebrew service from 0.1/0.2. Two copies would fight over the mouse, so `start` refuses
/// while it is still installed.
let oldBrewService = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/LaunchAgents/sh.brew.lost-buttons.plist")

func describe(_ status: SMAppService.Status) -> String {
  switch status {
  case .enabled: return "running in the background, and starts at every login"
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
    log("The old Homebrew service is still installed. Stop it first, then run this again:\n"
      + "  brew services stop lost-buttons")
    return 1
  }
  registerAppBundle()
  // macOS may not see a freshly installed app at once (.notFound); retry for up to 10 s.
  var firstAttempt = true
  for _ in 0..<10 {
    let notFound = agent.status == .notFound
    if firstAttempt && notFound { try? agent.unregister() }  // clears a stale record; harmless if none
    firstAttempt = false
    do { try agent.register() } catch { log("Could not start: \(error.localizedDescription)") }
    if registered(agent.status) || agent.status != .notFound { break }
    Thread.sleep(forTimeInterval: 1)
  }
  // register() leaves a running job alone, so after `brew upgrade` the old version (from the old
  // Cellar folder) would keep running until logout. Restarting runs this copy.
  if agent.status == .enabled { restartAgent() }
  log("Lost Buttons is \(describe(agent.status))")
  if agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
  return registered(agent.status) ? 0 : 1
}

func restartAgent() {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
  p.arguments = ["kickstart", "-k", "gui/\(getuid())/com.saaquiblabs.lost-buttons"]
  try? p.run()
  p.waitUntilExit()
}

func stopService() -> Int32 {
  do { try agent.unregister() } catch { log("Could not stop: \(error.localizedDescription)") }
  log("Lost Buttons is \(describe(agent.status))")
  return registered(agent.status) ? 1 : 0
}

func printStatus() {
  log("Lost Buttons \(version) is \(describe(agent.status))")
}
