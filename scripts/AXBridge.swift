import Foundation
import AppKit
import ApplicationServices
import CryptoKit

// Compile once. One app-scoped process, live AX handles, main-run-loop observer.
struct BridgeError: Error { let message: String }
func fail(_ message: String) throws -> Never { throw BridgeError(message: message) }
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func attribute(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil
}
func element(_ v: CFTypeRef?) -> AXUIElement? {
    guard let v = v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(v, to: AXUIElement.self)
}
func string(_ e: AXUIElement, _ key: String) -> String {
    guard let v = attribute(e, key) else { return "" }
    if let s = v as? String { return String(s.prefix(240)) }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func bool(_ e: AXUIElement, _ key: String, fallback: Bool = false) -> Bool {
    return (attribute(e, key) as? NSNumber)?.boolValue ?? fallback
}
func actions(_ e: AXUIElement) -> [String] {
    var list: CFArray?
    guard AXUIElementCopyActionNames(e, &list) == .success else { return [] }
    return (list as? [String] ?? []).filter { ["AXPress", "AXShowMenu"].contains($0) }
}
func writable(_ e: AXUIElement) -> Bool {
    var result: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(e, "AXValue" as CFString, &result) == .success && result.boolValue
}
func label(_ e: AXUIElement) -> String {
    for key in ["AXTitle", "AXDescription", "AXHelp", "AXPlaceholderValue"] {
        let s = string(e, key)
        if !s.isEmpty { return s }
    }
    return ""
}
func secure(_ e: AXUIElement) -> Bool { string(e, "AXSubrole") == "AXSecureTextField" }
func signature(_ e: AXUIElement) -> [String] {
    return [string(e, "AXRole"), string(e, "AXIdentifier"), label(e),
            secure(e) ? "<redacted>" : string(e, "AXValue"),
            bool(e, "AXEnabled", fallback: true) ? "1" : "0"]
}
func facts(_ e: AXUIElement) -> [String: Any] {
    // One IPC for the common attributes instead of individual requests.
    let names = ["AXRole", "AXIdentifier", "AXTitle", "AXDescription", "AXHelp",
                 "AXPlaceholderValue", "AXSubrole", "AXValue", "AXEnabled"]
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(e, names as CFArray,
          AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
          let array = values as? [Any], array.count == names.count else { return [:] }
    var result: [String: Any] = [:]
    for (key, value) in zip(names, array) {
        if let s = value as? String {
            result[key] = String(s.prefix(240))
            if s.count > 240 { result[key + "Truncated"] = true }
        }
        else if let n = value as? NSNumber { result[key] = n }
    }
    return result
}
func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

final class Bridge {
    let app: NSRunningApplication
    let root: AXUIElement
    let bundleID: String
    var observer: AXObserver?
    var watches: [(AXUIElement, String)] = []
    var epoch = 0
    var snapshotEpoch = 0
    var lastEvent = now()
    var snapshotTime = 0.0
    var snapshotID = ""
    var snapshotWindow: AXUIElement?
    var handles: [String: AXUIElement] = [:]
    var signatures: [String: [String]] = [:]
    var consumed = false

    init(_ bundle: String) throws {
        guard AXIsProcessTrusted() else { try fail("accessibility_permission_required") }
        // Respect host restrictions; this helper is not a path around them.
        let blocked = ["com.apple.Terminal", "com.googlecode.iterm2", "com.openai.chat", "com.openai.codex",
                       "com.apple.systempreferences", "com.apple.SecurityAgent"]
        guard !blocked.contains(bundle) else { try fail("restricted_app") }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        guard apps.count == 1 else { try fail("app_must_be_running_and_unambiguous") }
        app = apps[0]
        bundleID = bundle
        root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context = context else { return }
            let bridge = Unmanaged<Bridge>.fromOpaque(context).takeUnretainedValue()
            bridge.epoch += 1
            bridge.lastEvent = now()
        }
        if AXObserverCreate(app.processIdentifier, callback, &obs) == .success, let obs = obs {
            observer = obs
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            for name in ["AXFocusedWindowChanged", "AXFocusedUIElementChanged", "AXWindowCreated", "AXLayoutChanged"] {
                watch(root, name)
            }
        }
    }

    func watch(_ element: AXUIElement, _ name: String) {
        guard let observer = observer else { return }
        if AXObserverAddNotification(observer, element, name as CFString,
            Unmanaged.passUnretained(self).toOpaque()) == .success {
            watches.append((element, name))
        }
    }

    func pump() { _ = CFRunLoopRunInMode(.defaultMode, 0.001, true) }

    func checkApp() throws {
        guard !app.isTerminated, app.bundleIdentifier == bundleID else { try fail("app_identity_changed") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            try fail("target_app_not_frontmost")
        }
    }

    func snapshot(_ request: [String: Any]) throws -> [String: Any] {
        try checkApp()
        pump()
        let captureEpoch = epoch
        let started = now()
        // Remove window/element watches; keep only root watches.
        if let observer = observer {
            for (e, n) in watches where !CFEqual(e, root) {
                AXObserverRemoveNotification(observer, e, n as CFString)
            }
            watches.removeAll { !CFEqual($0.0, root) }
        }
        guard let window = element(attribute(root, "AXFocusedWindow")) else { try fail("no_focused_window") }
        snapshotWindow = window
        handles.removeAll()
        signatures.removeAll()
        var nodes: [[String: Any]] = []
        var visited: [AXUIElement] = []
        var truncated = false
        var errors = 0
        var queue: [(AXUIElement, Int, String)] = [(window, 0, "")]
        if request["include_menu"] as? Bool == true,
           let menu = element(attribute(root, "AXMenuBar")) { queue.append((menu, 0, "Menu bar")) }
        var cursor = 0
        while cursor < queue.count {
            if nodes.count >= 250 || now() - started > 1.5 { truncated = true; break }
            let (e, depth, parent) = queue[cursor]
            cursor += 1
            if visited.contains(where: { CFEqual($0, e) }) { continue }
            visited.append(e)
            let f = facts(e)
            let role = f["AXRole"] as? String ?? ""
            if role.isEmpty { errors += 1; continue }
            let name = ["AXTitle", "AXDescription", "AXHelp", "AXPlaceholderValue"]
                .compactMap { f[$0] as? String }.first { !$0.isEmpty } ?? ""
            let id = "e\(nodes.count)", isSecure = f["AXSubrole"] as? String == "AXSecureTextField"
            let value = (f["AXValue"] as? String) ?? (f["AXValue"] as? NSNumber)?.stringValue ?? ""
            let enabled = (f["AXEnabled"] as? NSNumber)?.boolValue ?? true
            let isWritable = !isSecure && ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) && writable(e)
            var node: [String: Any] = ["id": id, "role": role, "label": name,
                "identifier": f["AXIdentifier"] as? String ?? "", "parent_label": parent,
                "enabled": enabled, "secure": isSecure,
                "settable": isWritable, "actions": isSecure ? [] : actions(e),
                "value_truncated": f["AXValueTruncated"] as? Bool ?? false,
                "label_truncated": ["AXTitle", "AXDescription", "AXHelp", "AXPlaceholderValue"]
                    .contains { f[$0 + "Truncated"] as? Bool == true }]
            if !isSecure { node["value"] = value }
            nodes.append(node)
            handles[id] = e
            signatures[id] = [role, f["AXIdentifier"] as? String ?? "", name,
                              isSecure ? "<redacted>" : value, enabled ? "1" : "0"]
            if isWritable { watch(e, "AXValueChanged") }
            var childCount: CFIndex = 0
            let countError = AXUIElementGetAttributeValueCount(e, "AXChildren" as CFString, &childCount)
            if countError == .success && childCount > 0 {
                if depth >= 14 { truncated = true; continue }
                let take = min(childCount, 251 - nodes.count)
                var children: CFArray?
                if AXUIElementCopyAttributeValues(e, "AXChildren" as CFString, 0, take, &children) == .success {
                    for child in children as? [AXUIElement] ?? [] {
                        queue.append((child, depth + 1, name.isEmpty ? parent : name))
                    }
                } else { errors += 1 }
                if take < childCount { truncated = true }
            }
        }
        for name in ["AXUIElementDestroyed", "AXTitleChanged", "AXLayoutChanged"] { watch(window, name) }
        pump()
        guard epoch == captureEpoch else { try fail("snapshot_changed_during_capture") }
        snapshotEpoch = epoch
        snapshotTime = now()
        snapshotID = UUID().uuidString
        consumed = false
        let bytes = try JSONSerialization.data(withJSONObject: nodes, options: [.sortedKeys])
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ["ok": true, "snapshot": snapshotID, "bundle_id": bundleID,
                "pid": app.processIdentifier, "window": label(window), "nodes": nodes,
                "digest": digest, "truncated": truncated || errors > 0, "read_errors": errors,
                "observer_supported": observer != nil, "observe_ms": (now() - started) * 1000]
    }

    func act(_ request: [String: Any]) throws -> [String: Any] {
        let started = now()
        try checkApp()
        pump()
        guard request["snapshot"] as? String == snapshotID, !consumed,
              now() - snapshotTime <= 5.0 else { try fail("expired_snapshot") }
        guard epoch == snapshotEpoch else { try fail("stale_snapshot") }
        guard let oldWindow = snapshotWindow,
              let currentWindow = element(attribute(root, "AXFocusedWindow")),
              CFEqual(oldWindow, currentWindow) else { try fail("window_changed") }
        guard let id = request["target"] as? String, let target = handles[id],
              signature(target) == signatures[id] else { try fail("target_changed") }
        guard !secure(target), bool(target, "AXEnabled", fallback: true) else { try fail("target_unavailable") }
        let op = request["op"] as? String ?? ""
        var result: AXError = .failure
        if op == "press" || op == "show_menu" {
            let action = op == "press" ? "AXPress" : "AXShowMenu"
            guard actions(target).contains(action) else { try fail("unsupported_action") }
            consumed = true // Never retry an ambiguous mutation.
            result = AXUIElementPerformAction(target, action as CFString)
        } else if op == "set_value" {
            guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(string(target, "AXRole")),
                  writable(target), let text = request["text"] as? String, text.count <= 4000 else {
                try fail("unsupported_value_write")
            }
            consumed = true
            result = AXUIElementSetAttributeValue(target, "AXValue" as CFString, text as CFString)
        } else { try fail("unsupported_operation") }
        guard result == .success else { try fail("ax_action_failed_\(result.rawValue)") }
        return ["ok": true, "execute_ms": (now() - started) * 1000, "status": "AX_accepted"]
    }

    func settle(_ request: [String: Any]) -> [String: Any] {
        let started = now()
        let deadline = started + Double(min(max(request["timeout_ms"] as? Int ?? 600, 50), 2000)) / 1000
        // At least 60 ms, then stop after 40 ms of observed quiet. No claim that
        // quiet proves page loading complete; the next snapshot is authoritative.
        repeat {
            _ = CFRunLoopRunInMode(.defaultMode, 0.015, false)
        } while now() < deadline && (now() - started < 0.060 || now() - lastEvent < 0.040)
        return ["ok": true, "settle_ms": (now() - started) * 1000]
    }

    func handle(_ line: String) {
        do {
            guard let bytes = line.data(using: .utf8),
                  let req = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                try fail("invalid_request")
            }
            switch req["cmd"] as? String {
            case "snapshot": emit(try snapshot(req))
            case "act": emit(try act(req))
            case "settle": emit(settle(req))
            default: try fail("unknown_command")
            }
        } catch let e as BridgeError { emit(["ok": false, "error": e.message]) }
          catch { emit(["ok": false, "error": "bridge_internal_error"]) }
    }
}

if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--doctor" {
    emit(["ok": true, "accessibility_trusted": AXIsProcessTrusted(), "platform": "macOS"])
    exit(0)
}
guard CommandLine.arguments.count == 2 else {
    emit(["ok": false, "error": "usage_axbridge_bundle_id"])
    exit(2)
}
do {
    let bridge = try Bridge(CommandLine.arguments[1])
    Thread.detachNewThread {
        while let line = readLine() {
            DispatchQueue.main.async { bridge.handle(line) }
        }
        DispatchQueue.main.async { exit(0) }
    }
    RunLoop.main.run()
} catch let e as BridgeError {
    emit(["ok": false, "error": e.message])
    exit(2)
} catch {
    emit(["ok": false, "error": "bridge_initialization_failed"])
    exit(2)
}
