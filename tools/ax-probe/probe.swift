#!/usr/bin/env swift
//
// AX probe — dumps every AXUIElement under a target app whose label/title/help
// matches a search pattern (default "microphone"). Used to verify Google Meet's
// mic-button accessibility structure before wiring up live mute detection.
//
// Usage:
//   swift tools/ax-probe/probe.swift                       # default pattern + Chrome
//   swift tools/ax-probe/probe.swift microphone            # custom pattern
//   swift tools/ax-probe/probe.swift microphone com.brave.Browser
//
// Prereq: the process running this script (Terminal / iTerm / Xcode) must be
// in System Settings → Privacy & Security → Accessibility, otherwise every AX
// query returns -25204 (apiDisabled) and the dump is empty.

import Cocoa
import ApplicationServices

// MARK: - AX helpers

func axAttr<T>(_ element: AXUIElement, _ name: CFString) -> T? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, name, &value)
    guard err == .success else { return nil }
    return value as? T
}

func axString(_ element: AXUIElement, _ name: CFString) -> String? {
    axAttr(element, name)
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    axAttr(element, kAXChildrenAttribute as CFString) ?? []
}

func axValueDescription(_ element: AXUIElement) -> String {
    if let s = axString(element, kAXValueAttribute as CFString) {
        return s
    }
    if let n: NSNumber = axAttr(element, kAXValueAttribute as CFString) {
        return "\(n) (\(type(of: n)))"
    }
    return ""
}

// MARK: - Walk

final class WalkContext {
    let pattern: String
    var matches: Int = 0
    var visited: Int = 0
    init(pattern: String) { self.pattern = pattern.lowercased() }
}

func walk(_ element: AXUIElement, depth: Int, path: String, ctx: WalkContext) {
    ctx.visited += 1

    let role = axString(element, kAXRoleAttribute as CFString) ?? "?"
    let subrole = axString(element, kAXSubroleAttribute as CFString) ?? ""
    let title = axString(element, kAXTitleAttribute as CFString) ?? ""
    let desc = axString(element, kAXDescriptionAttribute as CFString) ?? ""
    let help = axString(element, kAXHelpAttribute as CFString) ?? ""
    let identifier = axString(element, kAXIdentifierAttribute as CFString) ?? ""
    let value = axValueDescription(element)

    let combined = "\(title) \(desc) \(help) \(identifier) \(value)".lowercased()
    if combined.contains(ctx.pattern) {
        ctx.matches += 1
        let indent = String(repeating: "  ", count: min(depth, 12))
        print("")
        print("\(indent)⭐ MATCH #\(ctx.matches) (depth=\(depth))")
        print("\(indent)   path=\(path)")
        print("\(indent)   role=\(role)\(subrole.isEmpty ? "" : " subrole=\(subrole)")")
        if !title.isEmpty { print("\(indent)   AXTitle=\"\(title)\"") }
        if !desc.isEmpty { print("\(indent)   AXDescription=\"\(desc)\"") }
        if !help.isEmpty { print("\(indent)   AXHelp=\"\(help)\"") }
        if !identifier.isEmpty { print("\(indent)   AXIdentifier=\"\(identifier)\"") }
        if !value.isEmpty { print("\(indent)   AXValue=\(value)") }

        // Walk up the parent chain so we know how to *find* this node from
        // the app root in the real detector.
        var ancestors: [String] = []
        var cursor: AXUIElement = element
        for _ in 0..<6 {
            guard let parent: AXUIElement = axAttr(cursor, kAXParentAttribute as CFString) else { break }
            let pRole = axString(parent, kAXRoleAttribute as CFString) ?? "?"
            let pTitle = axString(parent, kAXTitleAttribute as CFString) ?? ""
            ancestors.append("\(pRole)\(pTitle.isEmpty ? "" : "(\"\(pTitle)\")")")
            cursor = parent
        }
        if !ancestors.isEmpty {
            print("\(indent)   ancestors=\(ancestors.joined(separator: " ← "))")
        }

        // Dump every attribute name so we can spot useful state attrs (toggle
        // value, AXSelected, custom data-* exposed via AXIdentifier, etc.)
        var names: CFArray?
        if AXUIElementCopyAttributeNames(element, &names) == .success,
           let arr = names as? [String] {
            print("\(indent)   all-attrs=[\(arr.sorted().joined(separator: ", "))]")
        }
    }

    guard depth < 50 else { return }
    for (i, child) in axChildren(element).enumerated() {
        walk(child, depth: depth + 1, path: "\(path)>\(role)[\(i)]", ctx: ctx)
    }
}

// MARK: - Main

let pattern = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "microphone"
let bundleQuery = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "com.google.Chrome"

print("=== AX probe ===")
print("pattern   = \"\(pattern)\"")
print("bundleID  = \(bundleQuery)")
print("")

if !AXIsProcessTrusted() {
    print("⚠️  Accessibility permission NOT granted to this process.")
    print("    System Settings → Privacy & Security → Accessibility →")
    print("    enable the app running this script (Terminal / iTerm / Xcode).")
    print("    Then re-run.")
    exit(1)
}

let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleQuery }
guard !apps.isEmpty else {
    print("❌ No running app with bundleID \(bundleQuery)")
    print("   Open Chrome with a Google Meet tab and try again.")
    exit(1)
}

let started = Date()
let ctx = WalkContext(pattern: pattern)
for app in apps {
    print("=== App pid=\(app.processIdentifier) name=\(app.localizedName ?? "?")")
    let root = AXUIElementCreateApplication(app.processIdentifier)
    walk(root, depth: 0, path: "root(pid=\(app.processIdentifier))", ctx: ctx)
}
let elapsed = Date().timeIntervalSince(started)

print("")
print("=== Done. matches=\(ctx.matches) visited=\(ctx.visited) elapsed=\(String(format: "%.2f", elapsed))s")
