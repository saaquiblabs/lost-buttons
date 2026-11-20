// Finds mouse buttons that a device sends but its HID report descriptor never names.
//
// Some mice declare, say, 5 one-bit button fields but give Usages only to buttons 1-3
// (Usage Minimum 1, Usage Maximum 3, Report Count 5). macOS maps fields to Usages, so
// the extra bits (the side buttons) are dropped before any app can see them.
// Linux fixes these mice one by one with descriptor patches; we detect the pattern instead.

/// A run of button bits in one input report that have no Usage.
struct HiddenButtons: Equatable {
  /// Report ID, or 0 when the device does not use report IDs.
  let reportID: UInt8
  /// Bit offset of the first hidden button, counted from the start of the report
  /// payload (after the report ID byte, if any).
  let bitOffset: Int
  /// How many hidden buttons follow.
  let count: Int
  /// Button number of the first hidden bit (1-based, so 4 means "button 4").
  let firstButton: Int
}

private let buttonPage: UInt32 = 0x09

/// Parses a HID report descriptor and returns every hidden button run in its input reports.
/// Malformed or truncated descriptors return what was found before the problem; never traps.
func findHiddenButtons(_ d: [UInt8]) -> [HiddenButtons] {
  struct Globals { var usagePage: UInt32 = 0, reportSize = 0, reportCount = 0, reportID: UInt8 = 0 }
  var g = Globals()
  var stack: [Globals] = []
  // Locals, cleared after every main item.
  var usages: [UInt32] = []          // full 32-bit usages (page << 16 | id)
  var usageMin: UInt32?, usageMax: UInt32?
  var inputBits: [UInt8: Int] = [:]  // running bit offset per report ID
  var found: [HiddenButtons] = []

  func full(_ value: UInt32, _ size: Int) -> UInt32 {
    size == 4 ? value : (g.usagePage << 16) | value  // a 4-byte usage carries its own page
  }

  var i = 0
  while i < d.count {
    let prefix = d[i]
    if prefix == 0xFE {  // long item: FE, size, tag, data...
      guard i + 1 < d.count else { break }
      i += 3 + Int(d[i + 1])
      continue
    }
    let size = [0, 1, 2, 4][Int(prefix & 0x03)]
    guard i + size < d.count else { break }
    var value: UInt32 = 0
    for k in 0..<size { value |= UInt32(d[i + 1 + k]) << (8 * k) }
    i += 1 + size

    switch prefix & 0xFC {
    // Global items
    case 0x04: g.usagePage = value
    case 0x74: g.reportSize = Int(value)
    case 0x84: g.reportID = UInt8(truncatingIfNeeded: value)
    case 0x94: g.reportCount = Int(value)
    case 0xA4: stack.append(g)
    case 0xB4: if let top = stack.popLast() { g = top }
    // Local items
    case 0x08: usages.append(full(value, size))
    case 0x18: usageMin = full(value, size)
    case 0x28: usageMax = full(value, size)
    // Main items
    case 0x80:  // Input
      let isConstant = value & 0x01 != 0, isVariable = value & 0x02 != 0
      let offset = inputBits[g.reportID, default: 0]
      if !isConstant, isVariable, g.reportSize == 1 {
        var named = 0, highest: UInt32 = 0, page: UInt32 = 0
        if let lo = usageMin, let hi = usageMax, hi >= lo {
          named = Int(hi - lo) + 1; highest = hi; page = hi >> 16
        } else if let last = usages.last {
          named = usages.count; highest = usages.max() ?? last; page = last >> 16
        }
        if page == buttonPage, named > 0, g.reportCount > named {
          found.append(HiddenButtons(
            reportID: g.reportID, bitOffset: offset + named,
            count: g.reportCount - named, firstButton: Int(highest & 0xFFFF) + 1))
        }
      }
      inputBits[g.reportID] = offset + g.reportSize * g.reportCount
      usages = []; usageMin = nil; usageMax = nil
    case 0x90, 0xB0, 0xA0, 0xC0:  // Output, Feature, Collection, End Collection
      usages = []; usageMin = nil; usageMax = nil
    default: break
    }
  }
  return found
}

/// True if the descriptor declares any Button-page usage (a cheap "is this a pointing device" test).
func hasButtons(_ d: [UInt8]) -> Bool {
  var i = 0
  while i < d.count {
    let prefix = d[i]
    if prefix == 0xFE {
      guard i + 1 < d.count else { break }
      i += 3 + Int(d[i + 1])
      continue
    }
    let size = [0, 1, 2, 4][Int(prefix & 0x03)]
    guard i + size < d.count else { break }
    if prefix & 0xFC == 0x04 {
      var value: UInt32 = 0
      for k in 0..<size { value |= UInt32(d[i + 1 + k]) << (8 * k) }
      if value == buttonPage { return true }
    }
    i += 1 + size
  }
  return false
}
