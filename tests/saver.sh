#!/usr/bin/env bash
# Builds HotBag.saver into a temp dir, loads it the way the system host does
# (NSBundle + principal class), and renders frames into offscreen bitmaps.
# Nothing is installed, no window is shown, and no power or lock setting changes.
# Optional: pass a directory to keep the rendered PNGs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hot-bag-saver-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
OUT="${1:-$TMP/png}"
mkdir -p "$OUT"
bash "$ROOT/screensaver/saver/install.sh" build "$TMP" >/dev/null
cat > "$TMP/harness.swift" <<'SWIFT'
import Cocoa
import ScreenSaver
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let args = CommandLine.arguments
_ = NSApplication.shared
guard let bundle = Bundle(path: args[1]), bundle.load() else { fputs("FAIL: bundle did not load\n", stderr); exit(1) }
check(bundle.bundleIdentifier == "com.hot-bag.screensaver", "bundle identifier")
guard let saverClass = bundle.principalClass as? ScreenSaverView.Type else { fputs("FAIL: principal class is not a ScreenSaverView\n", stderr); exit(1) }
check(NSStringFromClass(saverClass) == "HotBagSaverView", "stable Objective-C class name")

// Count pixels brighter than the dim star field: sprites, toast and butter.
func bright(_ view: NSView) -> (count: Int, rep: NSBitmapImageRep) {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    var count = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            if let c = rep.colorAt(x: x, y: y), c.redComponent + c.greenComponent + c.blueComponent > 1.2 { count += 1 }
        }
    }
    return (count, rep)
}
func save(_ rep: NSBitmapImageRep, _ name: String) {
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2] + "/" + name))
}
func host(_ frame: NSRect) -> (NSWindow, ScreenSaverView) {
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.setFrame(frame, display: false)
    let view = saverClass.init(frame: NSRect(origin: .zero, size: frame.size), isPreview: false)!
    window.contentView = view
    return (window, view)
}
// Two side-by-side displays, never ordered on screen.
let (w1, left) = host(NSRect(x: 0, y: 0, width: 1512, height: 982))
let (w2, right) = host(NSRect(x: 1512, y: 0, width: 1512, height: 982))
check(left.animationTimeInterval > 0 && left.animationTimeInterval <= 1.0 / 20, "animates at a smooth rate")
check(!left.hasConfigureSheet, "no options sheet")
// The system draws a view before its first animation tick; that must be a
// plain black frame, never a crash.
_ = bright(left)
left.startAnimation(); right.startAnimation()
_ = bright(right)
// About 20 simulated seconds of real ticks, long enough for a butter breath.
for _ in 0..<200 {
    left.animateOneFrame(); right.animateOneFrame()
    usleep(100_000)
    RunLoop.current.run(until: Date())
}
let a = bright(left), b = bright(right)
save(a.rep, "display-left.png"); save(b.rep, "display-right.png")
check(a.count + b.count > 2000, "sprites are drawn (bright samples: \(a.count) + \(b.count))")
check(a.count > 0 && b.count > 0, "the one flock spans both displays (\(a.count), \(b.count))")
left.stopAnimation(); right.stopAnimation()
_ = (w1, w2)

// The System Settings thumbnail: a private flock scaled into a small view.
let small = saverClass.init(frame: NSRect(x: 0, y: 0, width: 320, height: 200), isPreview: true)!
small.startAnimation()
for _ in 0..<20 { small.animateOneFrame(); usleep(40_000) }
let c = bright(small)
save(c.rep, "thumbnail.png")
check(c.count > 200, "thumbnail draws sprites (bright samples: \(c.count))")
small.stopAnimation()
print("PASS: bundle loads, principal class, shared two-display flock renders, thumbnail renders")
SWIFT
swiftc -O -module-cache-path "${TMPDIR:-/tmp}/hot-bag-swift-cache" "$TMP/harness.swift" -o "$TMP/harness"
"$TMP/harness" "$TMP/HotBag.saver" "$OUT"
