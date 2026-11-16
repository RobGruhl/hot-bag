import Cocoa
import ImageIO

// ImageIO decodes the shipped GIF once; the drawing loop allocates no images.
final class ToastView: NSView {
    var frames: [CGImage] = []
    var dragonFrames: [CGImage] = []
    var emptyFrames: [CGImage] = []
    var toastSprite: CGImage!
    var flock: Flock!
    var desktopOrigin = CGPoint.zero
    var onToggleFullscreen: (() -> Void)?
    var onToggleStatus: (() -> Void)?
    var showStatus = true
    var lines = ["Reading run state…", "", ""]
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init(frame: NSRect, asset: String) throws {
        super.init(frame: frame)
        func load(_ path: String) throws -> [CGImage] {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil) else {
                throw NSError(domain:"hot-bag",code:1,userInfo:[NSLocalizedDescriptionKey:"Missing sprite GIF: \(path)"])
            }
            let images = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source,$0,nil) }
            guard !images.isEmpty else { throw NSError(domain:"hot-bag",code:2) }
            return images
        }
        frames = try load(asset)
        dragonFrames = try load(URL(fileURLWithPath:asset).deletingLastPathComponent().appendingPathComponent("butter-dragon.gif").path)
        let folder = URL(fileURLWithPath:asset).deletingLastPathComponent()
        emptyFrames = try load(folder.appendingPathComponent("empty-toaster.gif").path)
        toastSprite = try load(folder.appendingPathComponent("escaped-toast.png").path).first!
        autoresizingMask = [.width,.height]
    }
    func statusRect(at t: Double) -> CGRect {
        let w = bounds.width, h = bounds.height
        let width = min(560.0,max(240,w-40))
        return CGRect(x:20+(sin(t/47)+1)/2*max(0,w-width-40),y:28+(sin(t/61)+1)/2*max(0,h-190),width:width,height:142)
    }
    func globalStatusRect(at t: Double) -> CGRect {
        statusRect(at:t).offsetBy(dx:desktopOrigin.x,dy:desktopOrigin.y)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "q", "\u{1b}": NSApp.terminate(nil)
        case " ": flock.paused.toggle()
        case "h": onToggleStatus?()
        case "f": onToggleFullscreen?()
        default: break
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        let w = bounds.width, h = bounds.height, t = flock.time
        // Restrained parallax stars, drawn deterministically without random flicker.
        for i in 0..<65 {
            let x = (Double(i * 173 % 997) / 997 * (w + 10) - t * 2).truncatingRemainder(dividingBy: w + 10)
            let y = Double(i * 317 % 991) / 991 * h
            NSColor(calibratedWhite: i % 8 == 0 ? 0.3 : 0.12, alpha: 1).setFill()
            NSRect(x: x < 0 ? x + w + 10 : x, y: y, width: i % 8 == 0 ? 2 : 1, height: 1).fill()
        }
        // Every view clips the same global flock to its own monitor rectangle.
        for (bird, isDragon) in flock.birds.map({ ($0, false) }) + (flock.antagonistEnabled ? [(flock.dragon, true)] : []) {
            let sprites = isDragon ? dragonFrames : frames
            let x = bird.position.x - desktopOrigin.x
            let y = bird.position.y - desktopOrigin.y
            let size = bird.size
            guard NSRect(x: x-size, y: y-size, width: size*2, height: size*2).intersects(bounds) else { continue }
            let frame = (Int(t * 10 + bird.phase)) % sprites.count
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            // Subtle banking follows the flight path; mirror for rightward turns.
            let bank = max(-0.25, min(0.25, -bird.velocity.y / 220))
            let sincePop = t-bird.poppedAt
            let recoil = !isDragon && sincePop<0.65 ? sin(sincePop*32)*0.20*(1-sincePop/0.65) : 0
            ctx.rotate(by: bank+recoil)
            if isDragon, let puff = flock.breath {
                let pulse = sin(min(1,(t-puff.started)/0.85)*Double.pi)
                ctx.scaleBy(x:1+pulse*0.09,y:1-pulse*0.06)
            }
            if bird.velocity.x > 0 { ctx.scaleBy(x: -1, y: 1) }
            ctx.setAlpha(0.85)
            let rect = CGRect(x:-size/2,y:-size/2,width:size,height:size)
            if !isDragon && t<bird.toastReadyAt {
                ctx.draw(emptyFrames[frame % emptyFrames.count],in:rect)
                // The fresh slice gradually peeks back out during the last 0.7s.
                let refill = max(0,1-(bird.toastReadyAt-t)/0.7)
                if refill>0 { ctx.setAlpha(0.85*refill); ctx.draw(sprites[frame],in:rect) }
            } else { ctx.draw(sprites[frame],in:rect) }
            ctx.restoreGState()
        }
        drawBreakfast(ctx)
        ctx.setAlpha(1)
        if showStatus {
            let box = statusRect(at:t)
            let x = box.minX, y = box.minY, panelWidth = box.width
            NSColor.black.withAlphaComponent(0.85).setFill(); box.fill()
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let text = ["H O T   B A G   /   A F T E R   H O U R S", ""] + lines + ["", "Q / ESC exit · SPACE pause · H hide · F fullscreen"]
            for (i, line) in text.enumerated() {
                let color: NSColor = i == 0 ? NSColor(calibratedRed: 0.65, green: 0.56, blue: 0.37, alpha: 1) : NSColor(calibratedWhite: 0.53, alpha: 1)
                let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
                (line as NSString).draw(in: NSRect(x: x + 12, y: y + 120 - CGFloat(i * 17), width: panelWidth - 24, height: 17), withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            }
        }
    }
    func drawBreakfast(_ ctx: CGContext) {
        let t = flock.time
        ctx.saveGState()
        // Every screen clips effects against the same global obstacle rectangles.
        ctx.addRect(bounds)
        for box in flock.obstacles { ctx.addRect(box.offsetBy(dx:-desktopOrigin.x,dy:-desktopOrigin.y)) }
        ctx.clip(using:.evenOdd)
        ctx.translateBy(x:-desktopOrigin.x,y:-desktopOrigin.y)
        if let puff = flock.breath {
            let age = t-puff.started
            let reach = min(1,age/0.38)
            let opacity = min(1,age/0.08)*min(1,max(0,(0.85-age)/0.23))
            let delta = puff.destination-puff.source
            let normal = Vector(x:-delta.y,y:delta.x).unit()
            for j in 0..<34 {
                let f = Double(j)/33*reach
                let wobble = sin(Double(j)*2.3-age*22)*(4+f*14)
                let p = puff.source+delta*f+normal*wobble
                let radius = 3+f*10
                ctx.setFillColor(NSColor(calibratedRed:1,green:0.72+Double(j%3)*0.08,blue:0.20,alpha:opacity*(0.30+0.35*(1-f))).cgColor)
                ctx.fillEllipse(in:CGRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2))
                if j%4==0 {
                    ctx.setFillColor(NSColor(calibratedRed:1,green:0.94,blue:0.53,alpha:opacity).cgColor)
                    ctx.fill(CGRect(x:p.x-3,y:p.y-3,width:6,height:6))
                }
            }
        }
        for crumb in flock.crumbs {
            let alpha = max(0,1-(t-crumb.born)/crumb.lifetime)
            ctx.setFillColor(NSColor(calibratedRed:1,green:0.73,blue:0.25,alpha:alpha).cgColor)
            ctx.fill(CGRect(x:crumb.position.x,y:crumb.position.y,width:crumb.size,height:crumb.size))
        }
        for toast in flock.flyingToast {
            let age = t-toast.born
            ctx.saveGState()
            ctx.translateBy(x:toast.position.x,y:toast.position.y)
            ctx.rotate(by:age*toast.spin)
            // A quick squash-and-stretch spring into the air, then happy tumbling.
            let spring = max(0,1-age/0.25)
            ctx.scaleBy(x:1-spring*0.22,y:1+spring*0.32)
            ctx.setAlpha(min(1,max(0,18-age)))
            ctx.draw(toastSprite,in:CGRect(x:-toast.size/2,y:-toast.size/2,width:toast.size,height:toast.size))
            ctx.restoreGState()
        }
        for bird in flock.birds {
            let age = t-bird.poppedAt
            if age>=0 && age<0.65 {
                let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize:12,weight:.bold),.foregroundColor:NSColor(calibratedRed:1,green:0.86,blue:0.45,alpha:1-age/0.65)]
                ("pop!" as NSString).draw(at:CGPoint(x:bird.position.x+bird.size*0.2,y:bird.position.y+bird.size*0.36+age*30),withAttributes:attrs)
            }
        }
        ctx.restoreGState()
    }

}

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
