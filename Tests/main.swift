// Descriptor parser tests. Run with `make test`. No XCTest needed, so it works with only
import Foundation
// the Command Line Tools installed.

var failures = 0
func expect(_ name: String, _ got: [HiddenButtons], _ want: [HiddenButtons]) {
  if got == want { print("ok    \(name)") } else {
    failures += 1
    print("FAIL  \(name)\n      got  \(got)\n      want \(want)")
  }
}
func bytes(_ hex: String) -> [UInt8] {
  let clean = hex.filter { !$0.isWhitespace }
  return stride(from: 0, to: clean.count, by: 2).map {
    let s = clean.index(clean.startIndex, offsetBy: $0)
    return UInt8(clean[s..<clean.index(s, offsetBy: 2)], radix: 16)!
  }
}

// Mouse, Report ID 1, Usage Min 1 / Max 3 but Report Count 5: buttons 4 and 5 are hidden.
// This is the Kreo Chimera's pattern (it sends Back on bit 3 and Forward on bit 4).
let hiddenWithID = bytes("""
  05 01 09 02 a1 01 85 01 09 01 a1 00
  05 09 19 01 29 03 15 00 25 01 95 05 75 01 81 02
  95 01 75 03 81 01
  05 01 09 30 09 31 15 81 25 7f 75 08 95 02 81 06
  c0 c0
  """)
expect("hidden buttons, with report ID", findHiddenButtons(hiddenWithID),
       [HiddenButtons(reportID: 1, bitOffset: 3, count: 2, firstButton: 4)])

// Same, without report IDs.
let hiddenNoID = bytes("""
  05 01 09 02 a1 01 09 01 a1 00
  05 09 19 01 29 03 15 00 25 01 95 05 75 01 81 02
  95 01 75 03 81 01
  05 01 09 30 09 31 15 81 25 7f 75 08 95 02 81 06
  c0 c0
  """)
expect("hidden buttons, no report ID", findHiddenButtons(hiddenNoID),
       [HiddenButtons(reportID: 0, bitOffset: 3, count: 2, firstButton: 4)])

// A healthy 5-button mouse: Usage Max 5, Report Count 5. Nothing to do.
let healthy5 = bytes("""
  05 01 09 02 a1 01 85 01 09 01 a1 00
  05 09 19 01 29 05 15 00 25 01 95 05 75 01 81 02
  95 01 75 03 81 01
  05 01 09 30 09 31 15 81 25 7f 75 08 95 02 81 06
  c0 c0
  """)
expect("healthy 5-button mouse", findHiddenButtons(healthy5), [])

// A healthy 3-button mouse with 5 constant padding bits. Padding is not buttons.
let healthy3 = bytes("""
  05 01 09 02 a1 01 09 01 a1 00
  05 09 19 01 29 03 15 00 25 01 95 03 75 01 81 02
  95 01 75 05 81 01
  05 01 09 30 09 31 15 81 25 7f 75 08 95 02 81 06
  c0 c0
  """)
expect("healthy 3-button mouse with padding", findHiddenButtons(healthy3), [])

// Buttons listed one by one (Usage 1, Usage 2, Usage 3) with Report Count 5.
let explicitUsages = bytes("""
  05 01 09 02 a1 01 09 01 a1 00
  05 09 09 01 09 02 09 03 15 00 25 01 95 05 75 01 81 02
  95 01 75 03 81 01
  c0 c0
  """)
expect("explicit usages", findHiddenButtons(explicitUsages),
       [HiddenButtons(reportID: 0, bitOffset: 3, count: 2, firstButton: 4)])

// Hidden buttons in report 2, after an unrelated report 1. Offsets are per report.
let secondReport = bytes("""
  05 01 09 06 a1 01 85 01 05 07 19 e0 29 e7 15 00 25 01 75 01 95 08 81 02 c0
  05 01 09 02 a1 01 85 02 09 01 a1 00
  05 09 19 01 29 03 15 00 25 01 95 05 75 01 81 02
  95 01 75 03 81 01
  c0 c0
  """)
expect("hidden buttons in second report", findHiddenButtons(secondReport),
       [HiddenButtons(reportID: 2, bitOffset: 3, count: 2, firstButton: 4)])

// 4-byte usages that carry their own page (0x0009_0001 .. 0x0009_0003), Report Count 5.
let extendedUsages = bytes("""
  05 01 09 02 a1 01 09 01 a1 00
  1b 01 00 09 00 2b 03 00 09 00 15 00 25 01 95 05 75 01 81 02
  95 01 75 03 81 01
  c0 c0
  """)
expect("extended usages", findHiddenButtons(extendedUsages),
       [HiddenButtons(reportID: 0, bitOffset: 3, count: 2, firstButton: 4)])

// Push / Pop restore globals: the Pop must bring Report Count back to 5.
let pushPop = bytes("""
  05 01 09 02 a1 01 09 01 a1 00
  05 09 95 05 75 01 a4 95 08 b4
  19 01 29 03 15 00 25 01 81 02
  95 01 75 03 81 01
  c0 c0
  """)
expect("push and pop", findHiddenButtons(pushPop),
       [HiddenButtons(reportID: 0, bitOffset: 3, count: 2, firstButton: 4)])

// Real descriptors from this MacBook (keyboard/trackpad helpers, headset): nothing to do.
for hex in [
  "050c0901a101050c09cd09ea09e91500250195037501810295058105c0",
  "0600ff0aff00a101150026ff00750895018102c0",
  "0600ff0a0300a101150026ff00750895168102c0",
] { expect("real Apple descriptor \(hex.prefix(12))…", findHiddenButtons(bytes(hex)), []) }

// Garbage and truncation must never trap.
expect("empty", findHiddenButtons([]), [])
expect("truncated", findHiddenButtons(Array(hiddenWithID.prefix(17))), [])
expect("long item", findHiddenButtons([0xfe, 0x02, 0x10, 0x00, 0x00] + hiddenNoID),
       [HiddenButtons(reportID: 0, bitOffset: 3, count: 2, firstButton: 4)])
var rng = SystemRandomNumberGenerator()
for _ in 0..<2000 { _ = findHiddenButtons((0..<Int.random(in: 0..<64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }) }
print("ok    2000 random descriptors without a crash")

// hasButtons
if !hasButtons(hiddenWithID) || hasButtons(bytes("0600ff0aff00a101150026ff00750895018102c0")) {
  failures += 1; print("FAIL  hasButtons")
} else { print("ok    hasButtons") }

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
if failures > 0 { exit(1) }
