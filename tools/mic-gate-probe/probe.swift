#!/usr/bin/env swift
//
// Mic-gate probe — runs the same AX-walk + parser logic as Meeting.app's
// MicGate against a live target app, and prints state transitions in real
// time so we can verify Discord (and Meet) detection without rebuilding the
// app or interrupting an active recording.
//
// Usage:
//   swift tools/mic-gate-probe/probe.swift                       # default: Discord
//   swift tools/mic-gate-probe/probe.swift discord
//   swift tools/mic-gate-probe/probe.swift meet                  # Chrome / Google Meet
//   swift tools/mic-gate-probe/probe.swift discord --debug        # dump candidate buttons
//   swift tools/mic-gate-probe/probe.swift discord --duration 60  # poll for 60s (default 120)
//
// Prereq: the process running this script (Terminal / iTerm / Xcode) must
// be in System Settings → Privacy & Security → Accessibility, otherwise
// every AX query returns -25204 (apiDisabled) and the probe finds nothing.
//
// While the probe is running, toggle Mute / Unmute in Discord (or Meet) —
// the script prints a `[t+1.23s] muted → unmuted` line per committed
// transition. If nothing prints when you click Mute, run again with
// `--debug` to see every candidate button the parser saw.

import Cocoa
import ApplicationServices

// MARK: - AX helpers

func axAttr<T>(_ element: AXUIElement, _ name: CFString) -> T? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value as? T
}

func axString(_ element: AXUIElement, _ name: CFString) -> String? {
    axAttr(element, name)
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    axAttr(element, kAXChildrenAttribute as CFString) ?? []
}

// MARK: - Parsers (mirror Meeting/Capture/MicStateDetector.swift)

typealias Parser = (_ title: String?, _ description: String?) -> Bool?

let googleMeetParser: Parser = { _, description in
    guard let description else { return nil }
    let lc = description.lowercased()
    if lc.contains("turn off microphone") { return true }   // mic ON
    if lc.contains("turn on microphone") { return false }   // mic MUTED
    return nil
}

let discordParser: Parser = { title, description in
    for candidate in [title, description] {
        guard let raw = candidate else { continue }
        let lc = raw.lowercased()
        if lc.contains("deafen") { continue }   // ignore the deafen toggle
        if lc.hasPrefix("unmute") || lc == "unmute" { return false }
        if lc.hasPrefix("mute") || lc == "mute" { return true }
    }
    return nil
}

// MARK: - Target config

struct Target {
    let key: String
    let bundleID: String
    let label: String
    let parser: Parser
}

let targets: [String: Target] = [
    "discord": Target(key: "discord",
                      bundleID: "com.hnc.Discord",
                      label: "Discord",
                      parser: discordParser),
    "meet":    Target(key: "meet",
                      bundleID: "com.google.Chrome",
                      label: "Meet",
                      parser: googleMeetParser),
]

// MARK: - CLI parsing

var positional: [String] = []
var debug = false
var durationSeconds: TimeInterval = 120
var i = 1
let args = CommandLine.arguments
while i < args.count {
    let a = args[i]
    switch a {
    case "--debug", "-d":
        debug = true
    case "--duration":
        i += 1
        if i < args.count, let v = TimeInterval(args[i]) { durationSeconds = v }
    case "-h", "--help":
        print("""
        Usage: swift tools/mic-gate-probe/probe.swift [target] [--debug] [--duration N]
          target:     'discord' (default) or 'meet'
          --debug:    dump every candidate AXButton parser sees, even before commit
          --duration: seconds to poll before exiting (default 120)
        """)
        exit(0)
    default:
        positional.append(a)
    }
    i += 1
}

let targetKey = positional.first?.lowercased() ?? "discord"
guard let target = targets[targetKey] else {
    print("❌ Unknown target '\(targetKey)'. Use 'discord' or 'meet'.")
    exit(1)
}

// MARK: - Boot

print("=== Mic-gate probe ===")
print("target    = \(target.label) (\(target.bundleID))")
print("debug     = \(debug)")
print("duration  = \(Int(durationSeconds))s")
print("")

if !AXIsProcessTrusted() {
    print("⚠️  Accessibility permission NOT granted to this process.")
    print("    System Settings → Privacy & Security → Accessibility →")
    print("    enable the app running this script (Terminal / iTerm / Xcode).")
    exit(1)
}

let apps = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == target.bundleID
}
guard let app = apps.first else {
    print("❌ \(target.label) is not running (no process with bundleID \(target.bundleID)).")
    print("   Open it (and join a voice channel / meeting) and try again.")
    exit(1)
}

let pid = app.processIdentifier
print("✓ Found \(target.label) pid=\(pid) name=\(app.localizedName ?? "?")")
print("")

// MARK: - Walk

let maxWalkDepth = 60
var loggedCandidates = Set<String>()

func walkForMicButton(_ element: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth < maxWalkDepth else { return nil }

    let role = axString(element, kAXRoleAttribute as CFString) ?? ""
    if role == kAXButtonRole as String {
        let title = axString(element, kAXTitleAttribute as CFString)
        let desc = axString(element, kAXDescriptionAttribute as CFString)
        let parsed = target.parser(title, desc)

        if debug, (title != nil || desc != nil) {
            // In debug mode, log any AXButton with text — even ones the
            // parser rejects — so we can see what Discord actually exposes.
            let key = "\(title ?? "")|\(desc ?? "")"
            if !loggedCandidates.contains(key) {
                loggedCandidates.insert(key)
                let verdict: String
                if let p = parsed {
                    verdict = p ? "→ MATCH (mic ON)" : "→ MATCH (mic MUTED)"
                } else {
                    verdict = "(rejected)"
                }
                print("  [debug] AXButton title=\(title ?? "nil") desc=\(desc ?? "nil") \(verdict)")
            }
        }

        if parsed != nil {
            return element
        }
    }

    for child in axChildren(element) {
        if let found = walkForMicButton(child, depth: depth + 1) {
            return found
        }
    }
    return nil
}

func currentState(_ button: AXUIElement) -> Bool? {
    let title = axString(button, kAXTitleAttribute as CFString)
    let desc = axString(button, kAXDescriptionAttribute as CFString)
    return target.parser(title, desc)
}

// MARK: - Polling loop

let app_ax = AXUIElementCreateApplication(pid)
var cachedButton: AXUIElement?
var lastReported: Bool?
var pendingState: Bool?
var pendingSince: Date?
let hysteresis: TimeInterval = 0.30
var consecutiveNil = 0
var inLost = false
var lastCachedDescribed: String?

let started = Date()
let deadline = started.addingTimeInterval(durationSeconds)

print("Polling every 200ms. Toggle Mute / Unmute in \(target.label) to see transitions.")
print("Press Ctrl+C to exit early.")
print("")

func t() -> String {
    String(format: "t+%5.2fs", Date().timeIntervalSince(started))
}

while Date() < deadline {
    // Re-walk if cache is empty.
    if cachedButton == nil {
        if let button = walkForMicButton(app_ax, depth: 0) {
            cachedButton = button
            let title = axString(button, kAXTitleAttribute as CFString) ?? "nil"
            let desc = axString(button, kAXDescriptionAttribute as CFString) ?? "nil"
            let descKey = "title=\(title) desc=\(desc)"
            if descKey != lastCachedDescribed {
                lastCachedDescribed = descKey
                print("[\(t())] ✓ button located → \(descKey)")
            }
        } else {
            consecutiveNil += 1
            if consecutiveNil == 5, !inLost {
                inLost = true
                print("[\(t())] ⚠️  signal lost — \(target.label) mic button not visible")
                print("       (open the meeting / voice channel and bring it on-screen)")
            }
            Thread.sleep(forTimeInterval: 0.2)
            continue
        }
    }

    guard let button = cachedButton else { continue }

    if let observed = currentState(button) {
        if inLost {
            inLost = false
            print("[\(t())] ✓ signal recovered")
        }
        consecutiveNil = 0

        if observed != lastReported {
            let now = Date()
            if pendingState != observed {
                pendingState = observed
                pendingSince = now
            } else if let since = pendingSince, now.timeIntervalSince(since) >= hysteresis {
                let from = lastReported.map { $0 ? "ON" : "MUTED" } ?? "?"
                let to = observed ? "ON" : "MUTED"
                print("[\(t())] mic \(from) → \(to)")
                lastReported = observed
                pendingState = nil
                pendingSince = nil
            }
        } else {
            pendingState = nil
            pendingSince = nil
        }
    } else {
        // Cache went stale — clear and re-walk on next iteration.
        cachedButton = nil
        consecutiveNil += 1
        if consecutiveNil == 5, !inLost {
            inLost = true
            print("[\(t())] ⚠️  signal lost (cached button no longer parses)")
        }
    }

    Thread.sleep(forTimeInterval: 0.2)
}

print("")
print("=== Done. final state = \(lastReported.map { $0 ? "mic ON" : "mic MUTED" } ?? "unknown")")
