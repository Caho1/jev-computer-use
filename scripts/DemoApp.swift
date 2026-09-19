import AppKit

final class Demo: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let input = NSTextField(string: "")
    let status = NSTextField(labelWithString: "Ready")
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 230),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Jev Mac Lab"
        input.frame = NSRect(x: 30, y: 140, width: 420, height: 28)
        input.placeholderString = "Enter a search query"
        input.setAccessibilityLabel("Search query")
        input.setAccessibilityIdentifier("jev.query")
        let search = NSButton(title: "Search", target: self, action: #selector(searchNow))
        search.frame = NSRect(x: 30, y: 90, width: 100, height: 32)
        search.setAccessibilityIdentifier("jev.search")
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetNow))
        reset.frame = NSRect(x: 150, y: 90, width: 100, height: 32)
        reset.setAccessibilityIdentifier("jev.reset")
        status.frame = NSRect(x: 30, y: 40, width: 420, height: 28)
        status.setAccessibilityIdentifier("jev.status")
        for view in [input, search, reset, status] { window.contentView?.addSubview(view) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func searchNow() { status.stringValue = "Results for: " + input.stringValue }
    @objc func resetNow() { input.stringValue = ""; status.stringValue = "Ready" }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Demo()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
