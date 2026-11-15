import AppKit
import Carbon.HIToolbox
import Foundation
import SpikeKit

nonisolated final class HotKeyCounter: @unchecked Sendable {
  static let shared = HotKeyCounter()
  private let lock = NSLock()
  private var counts: [UInt32: Int] = [:]

  func fired(_ id: UInt32) { lock.withLock { counts[id, default: 0] += 1 } }
  func count(_ id: UInt32) -> Int { lock.withLock { counts[id] ?? 0 } }
}

nonisolated func hotKeyCallback(
  _ call: EventHandlerCallRef?, _ event: EventRef?, _ user: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event else { return OSStatus(eventNotHandledErr) }
  var id = EventHotKeyID()
  let status = GetEventParameter(
    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
    MemoryLayout<EventHotKeyID>.size, nil, &id)
  if status == noErr { HotKeyCounter.shared.fired(id.id) }
  return noErr
}

enum HotKeyProbe {
  static let spec = ProbeSpec(
    name: "input-hotkeys", items: ["hotkeys", "7t13-shortcuts"],
    summary: "symbolic hot keys, RegisterEventHotKey modifiers, posted chords vs hot keys",
    run: run)

  struct Combo {
    let name: String
    let key: Int
    let carbon: Int
    let modifierKeys: [Int]
  }

  static let combos: [Combo] = [
    Combo(
      name: "cmd+opt+ctrl+k", key: kVK_ANSI_K, carbon: cmdKey | optionKey | controlKey,
      modifierKeys: [kVK_Command, kVK_Option, kVK_Control]),
    Combo(
      name: "ctrl+opt+k", key: kVK_ANSI_K, carbon: controlKey | optionKey,
      modifierKeys: [kVK_Control, kVK_Option]),
    Combo(
      name: "cmd+ctrl+k", key: kVK_ANSI_K, carbon: cmdKey | controlKey,
      modifierKeys: [kVK_Command, kVK_Control]),
    Combo(
      name: "cmd+opt+k", key: kVK_ANSI_K, carbon: cmdKey | optionKey,
      modifierKeys: [kVK_Command, kVK_Option]),
    Combo(name: "ctrl+k", key: kVK_ANSI_K, carbon: controlKey, modifierKeys: [kVK_Control]),
    Combo(name: "opt+k", key: kVK_ANSI_K, carbon: optionKey, modifierKeys: [kVK_Option]),
    Combo(name: "shift+k", key: kVK_ANSI_K, carbon: shiftKey, modifierKeys: [kVK_Shift]),
    Combo(name: "f19", key: kVK_F19, carbon: 0, modifierKeys: []),
    Combo(name: "cmd+space", key: kVK_Space, carbon: cmdKey, modifierKeys: [kVK_Command]),
  ]

  static let deniedDefaults: [(String, Int, Int)] =
    [
      ("ctrl+f2", kVK_F2, controlKey), ("ctrl+f3", kVK_F3, controlKey),
      ("ctrl+f8", kVK_F8, controlKey), ("cmd+space", kVK_Space, cmdKey),
      ("ctrl+space", kVK_Space, controlKey), ("ctrl+left", kVK_LeftArrow, controlKey),
      ("ctrl+right", kVK_RightArrow, controlKey), ("ctrl+up", kVK_UpArrow, controlKey),
      ("ctrl+down", kVK_DownArrow, controlKey), ("shift+cmd+3", kVK_ANSI_3, shiftKey | cmdKey),
      ("shift+cmd+4", kVK_ANSI_4, shiftKey | cmdKey),
      ("shift+cmd+5", kVK_ANSI_5, shiftKey | cmdKey),
      ("f11", kVK_F11, 0), ("cmd+f5", kVK_F5, cmdKey),
    ]
    + [
      kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
      kVK_ANSI_8, kVK_ANSI_9,
    ]
    .enumerated().map { ("ctrl+\($0.offset + 1)", $0.element, controlKey) }

  static func run(_ options: ProbeOptions) async -> ProbeReport {
    var report = ProbeReport("input-hotkeys", items: spec.items)
    let symbolic = symbolicHotKeys()
    report.set("symbolic_hot_keys", .array(symbolic))
    var denied: [(String, JSON)] = []
    for (name, key, mods) in deniedDefaults {
      let match = symbolic.first { entry in
        entry["key_code"]?.intValue == key && carbonModifiers(entry) == mods
      }
      denied.append(
        (
          name,
          match.map { .bool($0["enabled"]?.boolValue == true) } ?? .string("not a symbolic hot key")
        ))
    }
    report.set("denied_defaults_enabled", .obj(denied))
    let enabled = denied.filter { $0.1.boolValue == true }.map(\.0)
    report.finding(
      "default-denied chords that are enabled system shortcuts here: \(enabled.joined(separator: ", "))"
    )

    guard InputGuard.begin(&report) else { return report }
    let rig = InputRig()
    await rig.show()
    var handler: EventHandlerRef?
    var eventSpec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &eventSpec, nil, &handler)

    var rows: [JSON] = []
    for (index, combo) in combos.enumerated() {
      var ref: EventHotKeyRef?
      let id = EventHotKeyID(signature: OSType(0x4453_4B48), id: UInt32(index + 1))
      let status = RegisterEventHotKey(
        UInt32(combo.key), UInt32(combo.carbon), id, GetApplicationEventTarget(), 0, &ref)
      var fired: [(String, JSON)] = []
      if status == noErr {
        for (tapName, tap) in [
          ("hid", CGEventTapLocation.cghidEventTap), ("session", .cgSessionEventTap),
        ] {
          guard await rig.focus() else {
            fired.append((tapName, .string("skipped: harness does not own the keyboard")))
            continue
          }
          let before = HotKeyCounter.shared.count(id.id)
          await Post.chord(combo.key, modifiers: combo.modifierKeys, tap: tap)
          await settle(ms: 350)
          fired.append((tapName, .bool(HotKeyCounter.shared.count(id.id) > before)))
          if combo.name == "cmd+space" { await dismissSpotlight() }
        }
      }
      if let ref { UnregisterEventHotKey(ref) }
      rows.append(
        .obj([
          ("combo", .string(combo.name)), ("register_status", .int(Int(status))),
          ("posted_chord_fired", .obj(fired)),
        ]))
    }
    if let handler { RemoveEventHandler(handler) }
    report.set("register_event_hot_key", .array(rows))
    for row in rows {
      let fired = row["posted_chord_fired"]?.members?.map {
        "\($0.key) \($0.value.boolValue.map { $0 ? "fired" : "did not fire" } ?? $0.value.stringValue ?? "?")"
      }
      report.finding(
        "RegisterEventHotKey \(row["combo"]?.stringValue ?? "?"): status \(row["register_status"]?.intValue ?? 0)"
          + (fired.map { "; posted chord " + $0.joined(separator: ", ") } ?? ""))
    }

    var effects: [(String, JSON)] = []
    if await rig.focus() {
      effects.append(("cmd+space", await spotlightEffect()))
      for (name, key) in [("ctrl+f2", kVK_F2), ("ctrl+f3", kVK_F3), ("ctrl+f8", kVK_F8)] {
        guard await rig.focus() else { break }
        let before = Focus.focusedElement()
        await Post.chord(key, modifiers: [kVK_Control])
        await settle(ms: 500)
        let after = Focus.focusedElement()
        await Post.chord(kVK_Escape)
        await settle(ms: 300)
        await Post.chord(kVK_Escape)
        await settle(ms: 200)
        effects.append(
          (
            name,
            .obj([
              ("focus_before", before), ("focus_after", after),
              (
                "focus_moved",
                .bool(before["pid"] != after["pid"] || before["role"] != after["role"])
              ),
            ])
          ))
      }
    } else {
      report.note("system shortcut effects skipped: the harness could not own the keyboard")
    }
    report.set("system_shortcut_effects", .obj(effects))
    for (name, effect) in effects {
      if name == "cmd+space" {
        report.finding(
          "posted cmd+space opened Spotlight: \(effect["spotlight_appeared"]?.boolValue == true)")
      } else {
        let after = effect["focus_after"]
        report.finding(
          "posted \(name): keyboard focus moved \(effect["focus_moved"]?.boolValue == true) to "
            + "\(after?["owner"]?.stringValue ?? after?["error"]?.stringValue ?? "?") "
            + "(\(after?["role"]?.stringValue ?? "?"))")
      }
    }
    await rig.tearDown()
    return report
  }

  static func symbolicHotKeys() -> [JSON] {
    var array: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&array) == noErr,
      let list = array?.takeRetainedValue() as? [[String: Any]]
    else { return [] }
    return list.map { entry in
      .obj([
        ("key_code", .from(foundation: entry[kHISymbolicHotKeyCode as String])),
        ("modifiers", .from(foundation: entry[kHISymbolicHotKeyModifiers as String])),
        ("enabled", .from(foundation: entry[kHISymbolicHotKeyEnabled as String])),
      ])
    }
  }

  static func carbonModifiers(_ entry: JSON) -> Int {
    (entry["modifiers"]?.intValue ?? 0) & (cmdKey | shiftKey | optionKey | controlKey)
  }

  static func spotlightWindows() -> Int {
    WindowList.onScreen().filter { $0.ownerName == "Spotlight" && ($0.layer ?? 0) > 0 }.count
  }

  static func spotlightEffect() async -> JSON {
    let before = spotlightWindows()
    await Post.chord(kVK_Space, modifiers: [kVK_Command])
    await settle(ms: 800)
    let during = spotlightWindows()
    await dismissSpotlight()
    return .obj([
      ("spotlight_windows_before", .int(before)), ("spotlight_windows_after_post", .int(during)),
      ("spotlight_appeared", .bool(during > before)),
      ("spotlight_windows_after_escape", .int(spotlightWindows())),
    ])
  }

  static func dismissSpotlight() async {
    for _ in 0..<2 where spotlightWindows() > 0 {
      await Post.chord(kVK_Escape)
      await settle(ms: 300)
    }
  }
}
