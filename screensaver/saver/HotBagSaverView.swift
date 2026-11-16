import Cocoa
import ScreenSaver

// The macOS system screen saver target. The system owns everything that makes
// this a real lock: starting on idle or a hot corner, dismissing on mouse or
// key input, and asking for the login password. This file only draws.

// One flock for the whole desktop. The system creates one HotBagSaverView per
// display inside a single host process, so the views share this world instead
// of each running a private simulation.
final class SaverWorld {
    static let shared = SaverWorld()
    private struct Member { weak var view: HotBagSaverView?; var reported: CGRect }
    private var members: [Member] = []
    private(set) var flock: Flock?
    private var last = ProcessInfo.processInfo.systemUptime
    private var lines: [String]?
    private var reading = false
    private var lastRead = -100.0

    // Called every frame by every full-size view; cheap unless a frame changed.
    func place(_ view: HotBagSaverView, at rect: CGRect) {
        members.removeAll { $0.view == nil }
        if let i = members.firstIndex(where: { $0.view === view }) {
            guard members[i].reported != rect else { return }
            members[i].reported = rect
        } else {
            members.append(Member(view: view, reported: rect))
        }
        layout()
    }
    func remove(_ view: HotBagSaverView) {
        members.removeAll { $0.view == nil || $0.view === view }
        if !members.isEmpty { layout() }
    }
    private func layout() {
        var rects = members.map { $0.reported }
        // The host normally gives each display's window its real global frame.
        // If it ever reports overlapping frames, fall back to a side-by-side
        // row so the flock still has distinct screens to roam.
        let overlapping = rects.indices.contains { i in
            rects.indices.contains { j in j > i && rects[i].intersects(rects[j]) }
        }
        if overlapping {
            var x = 0.0
            rects = rects.map { r in defer { x += r.width }; return CGRect(x: x, y: 0, width: r.width, height: r.height) }
        }
        guard !rects.isEmpty else { return }
        if let flock = flock { flock.setScreens(rects) } else { flock = Flock(screens: rects) }
        for (i, member) in members.enumerated() {
            member.view?.attach(flock: flock!, origin: rects[i].origin)
        }
        applyStatus()
    }
    private func applyStatus() {
        // Only the first display carries the telemetry panel, and only once a
        // read has actually succeeded: no data means no panel, never a guess.
        for (i, member) in members.enumerated() {
            member.view?.toast?.showStatus = i == 0 && lines != nil
            if let lines = lines { member.view?.toast?.lines = lines }
        }
    }
    func step() {
        guard let flock = flock else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(now - last, 0.1)
        // Several views tick in the same instant; only the first one advances.
        guard dt >= 0.004 else { return }
        last = now
        flock.obstacles = members.compactMap { $0.view?.toast }.filter { $0.showStatus }.map { $0.globalStatusRect(at: flock.time + dt) }
        flock.update(dt)
        if now - lastRead >= 5 { lastRead = now; refresh() }
    }
    // Best effort. The system hosts third-party savers in a sandbox that may
    // refuse to launch the CLI; a refused or failed read hides the panel.
    private func refresh() {
        guard !reading, let cli = Bundle(for: HotBagSaverView.self).object(forInfoDictionaryKey: "HotBagCLI") as? String, !cli.isEmpty else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            var result: [String]?
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [cli, "_screensaver-status"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if process.isRunning { process.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) {
                    let rows = Array(output.components(separatedBy: "\n").prefix(3))
                    if rows.contains(where: { !$0.isEmpty }) { result = rows }
                }
            } catch {}
            DispatchQueue.main.async {
                self.lines = result
                self.reading = false
                self.applyStatus()
            }
        }
    }
}

@objc(HotBagSaverView)
final class HotBagSaverView: ScreenSaverView {
    private(set) var toast: ToastView?
    // The System Settings thumbnail gets a private, scaled-down flock. The
    // isPreview flag has been unreliable across macOS releases, so size decides.
    private var miniature: Bool { bounds.width < 700 || bounds.height < 450 }
    private var privateFlock: Flock?
    private var privateLast = ProcessInfo.processInfo.systemUptime

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30
        guard let assets = Bundle(for: HotBagSaverView.self).resourcePath,
              let view = try? ToastView(frame: bounds, asset: assets + "/flying-toaster.gif") else { return }
        view.interactive = false
        view.showStatus = false
        view.footer = "Move the mouse or press a key to unlock"
        addSubview(view)
        toast = view
        // Recent macOS can leave the saver host running after the screen saver
        // is dismissed, still animating invisibly. Leave when the system says
        // the saver is stopping; the host is relaunched on the next start.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(saverWillStop), name: NSNotification.Name("com.apple.screensaver.willstop"), object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func saverWillStop() {
        SaverWorld.shared.remove(self)
        if !miniature { exit(0) }
    }
    func attach(flock: Flock, origin: CGPoint) {
        toast?.flock = flock
        toast?.desktopOrigin = origin
    }
    override func stopAnimation() {
        super.stopAnimation()
        SaverWorld.shared.remove(self)
    }
    override func draw(_ rect: NSRect) {
        NSColor.black.setFill(); rect.fill()
    }
    override func animateOneFrame() {
        guard let toast = toast else { return }
        if miniature {
            // Draw a 1280-point-wide world shrunk into the thumbnail.
            let world = CGSize(width: 1280, height: 1280 * bounds.height / max(1, bounds.width))
            if privateFlock == nil {
                toast.frame = bounds
                toast.setBoundsSize(world)
                let flock = Flock(screens: [CGRect(origin: .zero, size: world)])
                privateFlock = flock
                attach(flock: flock, origin: .zero)
            }
            let now = ProcessInfo.processInfo.systemUptime
            privateFlock?.update(min(now - privateLast, 0.1))
            privateLast = now
        } else {
            guard let window = window else { return }
            SaverWorld.shared.place(self, at: window.convertToScreen(convert(bounds, to: nil)))
            SaverWorld.shared.step()
        }
        guard toast.flock != nil else { return }
        toast.needsDisplay = true
    }
    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
