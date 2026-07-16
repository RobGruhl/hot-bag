// HotBagIndicator — a tiny menu-bar (NSStatusItem) agent that shows, at a
// glance, whether hot-bag is actively holding this Mac awake.
//
//   🔥  on      — watchdog alive AND clamshell sleep disabled (hot bagging)
//   ⚠️  wedged  — sleep override on but no live watchdog (needs `hot-bag doctor`)
//   (hidden)    — off; the icon disappears so it's only present when relevant
//
// It owns NO state of its own. Every poll shells out to `hot-bag
// _indicator-state`, which is the single source of truth (same on/wedged logic
// as `hot-bag status`). So the glanceable icon can never drift from the CLI.
//
// Design notes:
//  - LSUIElement / .accessory activation policy → no Dock icon, no app switcher
//    entry. It's purely a menu-bar resident.
//  - Polls on a Timer (default 5s; override with HOTBAG_POLL_SECS). The probe is
//    cheap and sudo-free by construction, so frequent polling is fine.
//  - The path to the hot-bag script is resolved at launch: $HOTBAG_BIN if set,
//    else `hot-bag` on PATH, else ~/.local/bin/hot-bag. Passed in by the
//    LaunchAgent plist so it works regardless of the user's interactive PATH.

import AppKit
import Foundation

// ── locate the hot-bag executable ────────────────────────────────────────────
func resolveHotBag() -> String {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["HOTBAG_BIN"], fm.isExecutableFile(atPath: env) {
        return env
    }
    // Search PATH so a `brew`/symlinked install is found without hardcoding.
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        for dir in path.split(separator: ":") {
            let cand = "\(dir)/hot-bag"
            if fm.isExecutableFile(atPath: cand) { return cand }
        }
    }
    let home = fm.homeDirectoryForCurrentUser.path
    return "\(home)/.local/bin/hot-bag"
}

// ── run `hot-bag _indicator-state` and return the first line ──────────────────
// Returns "off" on any failure: a broken probe must never imply we're awake.
func probeState(_ bin: String) -> String {
    guard FileManager.default.isExecutableFile(atPath: bin) else { return "off" }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: bin)
    proc.arguments = ["_indicator-state"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
    } catch {
        return "off"
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    let first = out.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    let token = first.trimmingCharacters(in: .whitespacesAndNewlines)
    switch token {
    case "on", "wedged", "off": return token
    default: return "off"
    }
}

// ── the menu-bar controller ───────────────────────────────────────────────────
final class Indicator: NSObject {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let bin = resolveHotBag()
    var lastState = ""
    var timer: Timer?

    func start() {
        buildMenu()
        refresh()
        let secs = Double(ProcessInfo.processInfo.environment["HOTBAG_POLL_SECS"] ?? "") ?? 5.0
        let t = Timer(timeInterval: max(1.0, secs), repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)   // keep firing while a menu is open
        timer = t
    }

    func buildMenu() {
        let menu = NSMenu()
        // Header line, updated each refresh to describe the current state.
        let header = NSMenuItem(title: "hot-bag", action: nil, keyEquivalent: "")
        header.tag = 100
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Status…", action: #selector(openStatus), keyEquivalent: "s").target = self
        menu.addItem(withTitle: "Run doctor (recover)", action: #selector(runDoctor), keyEquivalent: "d").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit indicator", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    func refresh() {
        let state = probeState(bin)
        if state == lastState { return }   // avoid needless redraws
        lastState = state
        guard let button = statusItem.button else { return }
        switch state {
        case "on":
            statusItem.isVisible = true
            button.title = "🔥"
            button.toolTip = "hot-bag: actively hot bagging (lid-close sleep disabled)"
            setHeader("🔥 Hot bagging — lid can stay closed")
        case "wedged":
            statusItem.isVisible = true
            button.title = "⚠️"
            button.toolTip = "hot-bag: WEDGED — sleep override on but no watchdog. Run doctor."
            setHeader("⚠️ Wedged — run doctor to restore sleep")
        default:   // off — hide the icon entirely so it's only present when relevant
            statusItem.isVisible = false
            button.title = ""
            button.toolTip = "hot-bag: off"
            setHeader("hot-bag: off")
        }
    }

    func setHeader(_ s: String) {
        statusItem.menu?.item(withTag: 100)?.title = s
    }

    // ── menu actions: open a Terminal running the relevant hot-bag command ─────
    // We deliberately launch a visible Terminal rather than running stop/doctor
    // silently — both can need sudo, and the user should see the output.
    func runInTerminal(_ subcommand: String) {
        let cmd = "\(shellQuote(bin)) \(subcommand)"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd)\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @objc func openStatus() { runInTerminal("status") }
    @objc func runDoctor()  { runInTerminal("doctor") }
    @objc func quit()       { NSApplication.shared.terminate(nil) }
}

// ── entry point ────────────────────────────────────────────────────────────────
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only: no Dock icon, no ⌘-Tab entry
let indicator = Indicator()
indicator.start()
app.run()
