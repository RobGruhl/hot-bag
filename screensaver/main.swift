import Cocoa

final class SaverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        styleMask.contains(.titled) ? super.constrainFrameRect(frameRect,to:screen) : frameRect
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    var views: [ToastView] = []
    var flock: Flock!
    var animation: Timer?
    var poll: Timer?
    var reading = false
    var rebuilding = false
    var windowed = CommandLine.arguments.contains("--windowed")
    var showStatus = true
    var lastTime = ProcessInfo.processInfo.systemUptime
    let args = CommandLine.arguments
    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildWindows()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        animation = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let dt = min(now-self.lastTime, 0.1)
            self.lastTime = now
            if self.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) {
                self.flock.obstacles = self.views.filter { $0.showStatus }.map { $0.globalStatusRect(at:self.flock.time + (self.flock.paused ? 0 : dt)) }
                self.flock.update(dt)
                self.views.forEach { $0.needsDisplay = true }
            }
        }
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    @objc func screensChanged() { rebuildWindows() }
    func rebuildWindows() {
        rebuilding = true
        defer { rebuilding = false }
        windows.forEach { $0.delegate = nil; $0.close() }
        windows = []; views = []
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let world = CGRect(x:0,y:0,width:1000,height:680)
        let rectangles = windowed ? [world] : screens.map { $0.frame }
        if flock == nil { flock = Flock(screens:rectangles) } else { flock.setScreens(rectangles) }
        do {
            for (index, screen) in (windowed ? [screens[0]] : screens).enumerated() {
                let rect = windowed ? world : screen.frame
                let view = try ToastView(frame: NSRect(origin: .zero, size: rect.size), asset: args[1]+"/flying-toaster.gif")
                view.flock = flock
                view.desktopOrigin = windowed ? .zero : screen.frame.origin
                view.showStatus = showStatus && index == 0
                view.onToggleFullscreen = { [weak self] in
                    guard let self = self else { return }
                    self.windowed.toggle(); self.rebuildWindows()
                }
                view.onToggleStatus = { [weak self] in
                    guard let self = self else { return }
                    self.showStatus.toggle()
                    for (i, v) in self.views.enumerated() { v.showStatus = self.showStatus && i == 0 }
                }
                let mask: NSWindow.StyleMask = windowed ? [.titled, .closable, .miniaturizable] : [.borderless]
                let window = SaverWindow(contentRect: rect, styleMask: mask, backing: .buffered, defer: false, screen:screen)
                window.isReleasedWhenClosed = false
                window.title = "Hot Bag • After Hours"
                window.backgroundColor = .black
                window.contentView = view
                window.delegate = self
                if windowed { window.center() }
                else {
                    window.level = .floating
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    window.setFrame(screen.frame, display: true)
                }
                // Use the actual content origin in global AppKit points, never pixels.
                if !windowed {
                    view.desktopOrigin = window.convertToScreen(view.convert(view.bounds,to:nil)).origin
                }
                windows.append(window); views.append(view)
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
            }
            NSApp.presentationOptions = windowed ? [] : [.autoHideDock, .autoHideMenuBar]
            NSApp.activate(ignoringOtherApps: true)
            if args.contains("--verify-layout") {
                for (i, view) in views.enumerated() {
                    let actual = windows[i].convertToScreen(view.convert(view.bounds,to:nil))
                    let expected = windowed ? actual : screens[i].frame
                    precondition(actual == expected, "Display content frame differs from configured screen")
                    precondition(view.bounds.size == expected.size, "Content view size differs from screen")
                    print("PASS \(screens[i].localizedName): screen=\(expected) content=\(actual) origin=\(view.desktopOrigin)")
                }
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            fputs("Screensaver: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }
    func refresh() {
        guard !reading else { return }
        reading = true
        let command = args[2]
        DispatchQueue.global(qos: .utility).async {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [command, "_screensaver-status"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var result = ["Run state unavailable", "No complete telemetry sample yet", ""]
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if process.isRunning { process.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) {
                    result = Array(output.components(separatedBy: "\n").prefix(3))
                }
            } catch {}
            let snapshot = result
            DispatchQueue.main.async { self.views.forEach { $0.lines = snapshot }; self.reading = false }
        }
    }
    func windowWillClose(_ notification: Notification) { if !rebuilding { NSApp.terminate(nil) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !rebuilding }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
