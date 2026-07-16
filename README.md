# hot-bag 🎒🔥

![hot-bag](hot-bag-graphic.png)

**Hot bagging** *(v.)*: kicking off a big Claude job, closing the laptop, and
running it in your backpack while you move.

You know that long-running Claude job you babysit at your desk? What if you
just… closed the lid, threw your MacBook in your backpack, tethered it to
your phone, and went outside like a person?

`hot-bag` keeps an **Apple Silicon Mac** running an unattended job while the
**lid is closed** and it's stowed in a bag — networked over your **phone's
tether**, powered by **battery or a USB-C power bank**, with **temperature,
battery, connectivity, and tether bytes logged every 30 seconds** so you get
a full health report when you stop. The real `pmset` magic, not just
`caffeinate` hopes and dreams. Always restores normal sleep on `stop`, so
your laptop doesn't become a pocket space heater forever.

> ⚠️ May void warranty. May melt snacks. May cause coworkers to ask why your backpack is humming.

```
hot-bag start     # before you close the lid
hot-bag status    # live reading, anytime (no sudo); shows data-used-so-far mid-run
hot-bag stop      # when the job's done — prints the run report
hot-bag report    # reprint the report for the latest run
hot-bag doctor    # detect-and-repair a wedged state (see "If things get wedged")
```

---

## The 3-step routine

1. **Turn the tether on** (the one thing no command can do for you):
   - *USB tether (best for a backpack):* plug the phone in, enable **Personal
     Hotspot** (iPhone) or **USB tethering** (Android). Wired = no dropouts and
     the phone charges.
   - *Wi-Fi tether:* join the phone's hotspot once.
2. **Plug in the power bank** (recommended — see *Power* below).
3. `hot-bag start` → enter your sudo password once → close the lid → go.

When you're back: open the lid, `hot-bag stop`, read the report.

---

## What `start` actually does

1. **Waits for internet over *any* link** (USB tether / Wi-Fi / Ethernet) — it
   does not hard-require a specific interface. Reports which link is live.
2. `sudo pmset -a disablesleep 1` — the **hard clamshell override**. This is the
   only thing that keeps an Apple Silicon Mac awake with the lid shut. Plain
   `caffeinate` does **not** survive a lid close; we also run `caffeinate -dimsu`
   as a second layer.
3. Launches a **background watchdog** that samples every 30s into a CSV under
   `~/.local/state/hot-bag/runs/` — temperature, battery, connectivity, and
   **bytes used over the tether** (so the report tells you how much phone data
   the run burned).
4. Lights a **🔥 in the menu bar** so you can see at a glance that hot-bag is
   holding the Mac awake. It disappears on `stop` — and removes itself if the
   watchdog ever dies, so it can't lie about a dead run. (Built once with the
   Xcode Command Line Tools' `swiftc`; skipped with a warning if that's not
   installed. `MENUBAR=0` turns it off.)

`stop` reverses all of it (`disablesleep 0`, kills watchdog + caffeinate) and
prints the report.

---

## Resilience & transparent fallback

**Network.** macOS already fails over between links on its own: if you have both
USB tether and Wi-Fi up, it routes through whichever is available and switches
automatically. `hot-bag` doesn't fight that — it logs which interface is live
each sample so you can see drops/switches in the report. Optionally, set
`WIFI_SSID`/`WIFI_PASSWORD` (see *Config*) and the watchdog will actively try to
**rejoin that hotspot** whenever the link goes down.

**Power.** The clamshell override uses `pmset -a` (all power sources), so it
**works on battery** — you do not need to be plugged in. Switching between the
internal battery and a USB-C power bank is handled by the hardware; nothing to
configure. Every sample logs `battery_pct` and `power_source` so the report shows
your drain. Optional low-battery safety (`LOW_BATT_ACTION=sleep`) lets the Mac
sleep *gracefully* (state preserved) before a hard power-off — off by default so
it never pauses your job uninvited.

---

## Temperature on Apple Silicon — read this

Apple Silicon has **no built-in command that prints CPU degrees** (unlike Intel).
This tool gets real numbers from [`smctemp`](https://github.com/narugit/smctemp)
(installed via `brew tap narugit/tap && brew install smctemp`):

- **GPU °C** reads directly.
- **CPU °C** needs retry flags to get a stable reading; we use `-i25 -n40`.
- If `smctemp` isn't installed, temps log as `NA` and the tool falls back to the
  **CPU speed-limit** signal (`pmset -g therm`), which drops below 100% only when
  the OS is throttling from heat or power starvation.

Each sample is labelled from the hottest sensor: `OK → WARM (≥80°C) → HOT (≥90°C)
→ CRITICAL (≥95°C)`, plus `THROTTLED` if the CPU speed limit fell below 100%.
Thresholds are configurable.

The report ends with a plain-English **verdict** that puts those numbers in
context for the bag scenario — what the peak temp actually means, whether the
CPU ever throttled (and what that cost you), how the battery and network held
up, and one concrete suggestion for the next run. Bands are deliberately
tighter than "desk normal" because airflow, not silicon, is the limit when
the lid is shut in a bag.

---

## ⚠️ The real risk is thermal, not software

Lid closed + zipped bag = **no airflow**. Apple Silicon will run full-tilt with
the override on and can overheat, throttle, or emergency-shutdown in an insulated
bag. **Leave the bag open/unzipped and don't bury the laptop.** The report's
`HOT`/`CRITICAL` counts tell you after the fact whether you got away with it.

---

## Limiting tether data (don't blow the data plan)

Every run reports **how much data went over the tether** (`tether data : ↓ … ↑ …`),
measured from the interface's byte counters — a close proxy for the cellular data
your phone billed. It counts *all* traffic on the link, not just Claude.

When the lid's closed in the bag, Claude is the only thing *actively* using the
network — the surprise data drain comes from **background system daemons**
(iCloud sync, software updates, Photos analysis, Time Machine cloud, Spotlight).

**Recommended: Low Data Mode** on the tether network. It tells macOS and
cooperating apps to defer that background traffic while your active Claude API
calls keep flowing. It's cooperative (not enforced), zero-risk, and set-and-forget.

- **Wi-Fi hotspot:** join the phone's hotspot, then *System Settings → Wi-Fi →
  Details… (next to the hotspot) → Low Data Mode → on*. It's **per-SSID**, so it
  sticks to that hotspot for every future session.
- **USB tether:** Low Data Mode usually has no toggle for the USB network service
  (it's a Wi-Fi/Cellular feature). On USB, use a hard `pf` bandwidth cap instead
  (not yet wired into this script — see CLAUDE.md "future ideas").

macOS has **no built-in per-process bandwidth limit**. True "only Claude gets
out" requires a per-app firewall (LuLu / Little Snitch); a hard ceiling on the
whole tether requires `pf` + `dnctl` dummynet.

## Config

All optional. Set as environment variables, or copy `config.example` to
`~/.config/hot-bag/config` and edit:

| Var | Default | Meaning |
|-----|---------|---------|
| `INTERVAL` | `30` | Seconds between samples |
| `WARN_C` / `HOT_C` / `CRIT_C` | `80` / `90` / `95` | Temp thresholds (°C) |
| `PING_HOST` | `1.1.1.1` | Connectivity check target |
| `WIFI_SSID` / `WIFI_PASSWORD` | *(blank)* | Wi-Fi to auto-rejoin on drop |
| `LOW_BATT_ACTION` | `none` | `sleep` = graceful sleep when low on battery |
| `LOW_BATT_PCT` | `7` | Battery % that triggers the safety |
| `MENUBAR` | `1` | Show 🔥 in the menu bar while a run is active (`0` = off) |

---

## Install

```bash
git clone <this repo> ~/Projects/hot-bag
cd ~/Projects/hot-bag
./install.sh                       # symlinks into ~/.local/bin (on your PATH)
brew tap narugit/tap && brew install smctemp   # for real °C (optional but recommended)
```

## Files

```
hot-bag           the script (start/stop/status/report/doctor + internal _watch)
install.sh        symlinks hot-bag into ~/.local/bin
config.example    optional config template
runs/             per-run CSV logs (gitignored; lives in ~/.local/state/hot-bag/runs)
CLAUDE.md         architecture notes for AI-assisted debugging
```

## sudo

The only privileged action is the single `pmset -a disablesleep` call in
start/stop — you're prompted once each. **The watchdog is deliberately
sudo-free** so it runs unattended without a password. (The optional low-battery
graceful-sleep uses `sudo -n` and therefore needs a passwordless sudoers rule for
`pmset` to fire unattended; otherwise it no-ops.)

If you cancel the sudo prompt during `stop`, the script keeps cleaning up but
prints a loud error and exits non-zero — the clamshell override will remain on
until you run `sudo pmset -a disablesleep 0` yourself (or `hot-bag doctor`).

## If things get wedged

If a crash, force-quit, or canceled sudo prompt leaves the Mac in
"lid-closed-awake" mode without a running watchdog, `hot-bag status` will say so
explicitly. The fix:

```bash
hot-bag doctor                       # auto: restore sleep, sweep stale state
# or, by hand:
sudo pmset -a disablesleep 0         # restore normal lid-close sleep
```

`doctor` only acts on processes and state it can prove belong to hot-bag — it
checks `ps` before killing PIDs from the pidfiles, and it only flips
`disablesleep` back to 0 if the `SLEEP_GUARD` marker confirms hot-bag set it
(otherwise it warns and leaves the system alone, so it won't clobber a
`disablesleep` someone set deliberately outside hot-bag).
