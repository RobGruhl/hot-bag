# CLAUDE.md — hot-bag

Context for AI-assisted iteration/debugging of this repo. Read this before
changing `hot-bag`.

## What this is

A single Bash script (`hot-bag`) that lets an **Apple Silicon** MacBook keep
running an unattended job with the **lid closed in a backpack** — affectionately
"**hot bagging**" — tethered to a phone for data and possibly on battery. It also samples health telemetry every
30s and prints a report on stop. Installed as a symlink in `~/.local/bin` via
`install.sh`. Target platform: macOS on Apple Silicon (M-series). Not tested on
Intel.

## The core mechanism (don't regress this)

- **Lid-closed-awake requires `sudo pmset -a disablesleep 1`.** This is the only
  thing that overrides clamshell sleep on Apple Silicon. `caffeinate` alone does
  NOT survive a lid close — it's kept only as a secondary idle-sleep guard
  (`caffeinate -dimsu -w <watchdog-pid>`, backgrounded, pid in `caffeinate.pid`).
- `stop` MUST restore `pmset -a disablesleep 0`, or the user's Mac will never
  sleep again on lid close. This is the most important invariant. `stop` does
  NOT rely on `set -e` for that call: if sudo fails or the user cancels the
  prompt, it surfaces a loud error and exits non-zero — but it still tries to
  kill the watchdog and clean up afterwards.
- `start` arms a `trap` on `INT TERM HUP EXIT` that flips `disablesleep` back to
  0 if start aborts after the override was set (Ctrl-C, sudo failure on a later
  step, etc.). The trap is disarmed on successful handoff so the override
  persists for the actual run. The `SLEEP_GUARD` marker file at
  `$HOTBAG_HOME/disablesleep.on` records that *we* set the override (the
  `doctor` command uses it).
- `caffeinate -dimsu -w <watchdog-pid>` ties caffeinate's lifetime to the
  watchdog. A second `start` can no longer orphan an earlier caffeinate, and
  if the watchdog dies caffeinate exits with it. Don't drop the `-w`.
- `pmset -a` (all power sources) is intentional so it works **on battery**, not
  just AC.
- All PID-based kills go through `safe_ps_match` (PID exists AND its command
  contains the expected string). `kill -0` alone can't tell our process apart
  from a PID-reused stranger.
- `start` and `stop` take a mutex via `mkdir $LOCKDIR` so they can't overlap.
- **Admin preflight before every sudo.** On managed Macs the user is a STANDARD
  user until they temporarily elevate (commonly via SAP's **Privileges.app**).
  Calling `sudo` while not in the admin group makes sudo itself print a hostile
  "not in the sudoers file; this incident will be reported." So `ensure_admin`
  runs *before* each `sudo pmset` in `start`/`stop`/`doctor`: it checks group
  membership with `dseditgroup -o checkmember … admin` (LIVE directory state —
  reflects a just-granted elevation, unlike `id`'s stale process groups, and is
  what sudo itself consults), and if not elevated, offers to run `PrivilegesCLI
  --add`, polls until admin lands, then proceeds. No CLI or no TTY → it prints
  the manual steps and returns non-zero *before* sudo runs. **Invariant: never
  call `sudo pmset` without an `ensure_admin` guard in front of it.** In `stop`,
  a failed/declined elevation must NOT abort the rest of cleanup — the watchdog
  and caffeinate are killed sudo-free regardless, and `stop` exits non-zero so
  the still-on override is loud. The elevation is the user's call every time
  (interactive `[y/N]`); we never elevate silently.
- `doctor` is the recovery path when something *did* go wrong (crash, force
  reboot, canceled sudo): it restores sleep **only if `SLEEP_GUARD` exists**
  (proof hot-bag set the override), kills only processes verified by
  `safe_ps_match`, and removes stale state files. Do not regress to a bare
  `pkill caffeinate` or to restoring `disablesleep` unconditionally — both
  would clobber unrelated state on the user's machine.
- `_watch` runs its sampling loop with `set +eo pipefail`. The whole point of
  the watchdog is to log transient failures, not to die on them — a flaky
  network reader or a momentary `smctemp` glitch must produce a row with NA
  values, not kill the logger. Readers all have fallback strings; the
  `set +e` just stops the first transient from propagating.
- Numeric config (`INTERVAL`, `WARN_C`, `HOT_C`, `CRIT_C`, `LOW_BATT_PCT`) is
  validated up-front at script load time. Bad values fail fast with a clear
  error, not at some arithmetic-error mile down the road.
- `thermal_state()` returns `UNKNOWN` (not `OK`) when both CPU and GPU are
  `NA`. A thermal-safety tool that claims OK with no temperature data is
  worse than one that says "I can't tell." `start` warns explicitly if
  `smctemp` is missing.

## Architecture

Subcommands dispatched via a `case` at the bottom:
- `start` — wait for internet (any link), baseline reading, `disablesleep 1`,
  spawn `caffeinate`, spawn the watchdog detached via `nohup "$0" _watch <log> &`,
  then spawn the lid-close chime watcher (`_lidwatch`) unless `LID_CHIME=off`.
- `stop` — `disablesleep 0` (non-fatal on failure), kill watchdog + caffeinate +
  lid watcher via `safe_ps_match`, sweep any stragglers with `pkill -f "$0
  _watch"` / `pkill -f "$0 _lidwatch"`, then `diagnose_caffeinate` and `report`.
  Exits non-zero if the restore step failed
  so the user notices. Takes an optional `--kill-stray-caffeinate` flag (parsed
  *before* `acquire_lock` so a bad flag can't strand the lock).
- `status` — one-shot live reading (no sudo, no side effects). When a run is
  active (watchdog pid alive + `current-run` present), it also prints `data this
  run` by folding the live byte counters into `run_data_used()`. Warns loudly
  if the sleep override is on but no watchdog is running (wedged state).
- `report [logfile]` — summarize a CSV (defaults to current/latest run).
- `doctor` — recovery: restore `disablesleep 0` if it's on, sweep stale
  `_watch`/`caffeinate` processes, remove stale pid/lock/state files. Safe to
  run any time.
- `chime` — preview the 8-bit lid-close reminder sound (no sudo, no run needed).
- `_watch <logfile>` — **internal**; the background sampling loop. Re-enters the
  same script so config flows in via exported env vars from `start`.
- `_lidwatch` — **internal**; the lid-close chime watcher (see "Lid-close chime").
- `_indicator-state` — **internal**; prints `on|wedged|off` for the menu-bar
  indicator (see "Menu-bar indicator"). Cheap and side-effect-free (NO ping, no
  sudo) so it's safe to poll every few seconds. `on`/`wedged` mirror the exact
  on/wedged logic `status` uses (`watchdog_alive` + `SleepDisabled`), so the
  glanceable icon can never disagree with the command. Keep it that way.

### Lid-close chime (`_lidwatch`)

An **opt-outable** audible reminder: when the lid closes during a run, play an
8-bit sound so the user knows hot-bag is still going before the Mac goes in the
bag. Fully **sudo-free** and decoupled — the CLI works whether or not it fires.

- `start` spawns `_lidwatch` detached (`nohup "$0" _lidwatch &`, pid in
  `lidwatch.pid`) right after caffeinate, and pre-generates the sound so the
  first lid-close isn't delayed. Skipped entirely if `LID_CHIME=off` or `afplay`
  is missing (warns in the latter case).
- `_lidwatch` polls `lid_state()` every **2s** (deliberately faster than the 30s
  telemetry cadence — the chime must fire *before* the lid is in the bag) and
  calls `play_chime` on each **open→closed transition** only. It seeds `prev`
  with the current state so a run started with the lid already shut doesn't
  chime, and treats `unknown` reads as "keep last known state" so an `ioreg`
  blip can't spuriously fire it.
- **Lifecycled to the watchdog**, exactly like caffeinate: the loop condition is
  `while watchdog_alive; do …`, so if the watchdog dies the chime watcher exits
  on its own (within ~2s). It can never outlive a run. `stop`/`doctor` also kill
  it explicitly via `safe_ps_match "$lp" "hot-bag _lidwatch"` + a
  `pkill -f "$0 _lidwatch"` sweep, and remove `lidwatch.pid`.
- `lid_state()` reads `ioreg -r -k AppleClamshellState` (No=open, Yes=closed) —
  **sudo-free** and cheap (~35ms). This is the only no-install, no-admin way to
  observe the lid on Apple Silicon. Don't regress it to something needing sudo.
- The sound is a square-wave arpeggio (C5-E5-G5-C6) synthesized as an 8-bit
  unsigned PCM WAV by an **embedded `perl` heredoc** in `generate_chime()`
  (core perl only — matches the repo's no-third-party-deps ethos), cached at
  `chime.wav` under `HOTBAG_HOME`. `LID_CHIME_FILE` overrides it with the user's
  own audio (any format `afplay` reads — generation is then skipped);
  `LID_CHIME_VOLUME` maps to `afplay -v`. `play_chime` is best-effort: it
  backgrounds the play and never errors the caller.
- **Scoped unmute** (`LID_CHIME_UNMUTE`, default on): if the Mac is muted,
  `play_chime_scoped()` saves the current mute+volume via `osascript`, unmutes
  (nudging volume off 0), plays in the **foreground** (so we don't re-mute
  mid-beep), then restores the EXACT prior state. It only ever unmutes for the
  duration of the one chime — a deliberate mute is respected everywhere else.
  This is the ONE place hot-bag mutates unrelated user state, so it's guarded
  hard: every `osascript`/`afplay` step is `|| true` so a failure under `set -e`
  can't strand the Mac unmuted, and the restore always runs. `LID_CHIME_UNMUTE=off`
  plays into the mute (silent) and never touches audio settings. When editing,
  keep the play foreground *inside* the unmute window and keep the restore
  unconditional — do not regress to a background play there (it would re-mute
  before the sound finished) or drop the `|| true` guards.
- `status` shows a `lid chime` line during a live run (armed / off / not
  running), gated the same way as the watchdog line.

### `diagnose_caffeinate` and the stray-caffeinate rule

`stop` (and only `stop`) calls `diagnose_caffeinate <our_caff_pid> <kill 0|1>`
after releasing its own caffeinate. It lists *other* caffeinate processes still
holding sleep open and classifies each by its flags (`-d` ⇒ display+system sleep;
no `-d` ⇒ idle-only, which does NOT block lid-close; `-t` ⇒ auto-expires).
**Report-only by default** — it does NOT kill foreign caffeinate unless the user
passed `--kill-stray-caffeinate`. This is the same invariant as `doctor`: never a
bare `pkill caffeinate` (it would whack the user's unrelated terminal/Claude/
editor caffeinate sessions). The only caffeinate `stop` kills unconditionally is
its own, verified via `safe_ps_match`.

## Menu-bar indicator (`indicator/`)

Optional, **opt-in**, and fully decoupled — the CLI never depends on it. A tiny
native Swift menu-bar agent (`NSStatusItem`, `.accessory` activation so no Dock
icon) that polls `hot-bag _indicator-state` every few seconds and shows 🔥 (on) /
⚠️ (wedged) / hidden (off). Built with the system `swiftc` (Xcode CLT) — no
SwiftBar/xbar, no Homebrew, no third-party deps. Launched by a per-user
LaunchAgent (`gui/<uid>` domain).

- `indicator/HotBagIndicator.swift` — the agent. Owns NO state: it shells out to
  `hot-bag _indicator-state` for every poll, so it's a pure view over the CLI's
  truth. On any probe failure it falls back to `off` (a broken probe must never
  imply the Mac is awake). `HOTBAG_BIN` overrides the script path; `HOTBAG_POLL_SECS`
  the interval (default 5).
- `indicator/com.hot-bag.indicator.plist.template` — LaunchAgent template;
  `install.sh` substitutes `__BIN__/__HOTBAG__/__POLL__/__LOG__` and writes it to
  `~/Library/LaunchAgents/`. The `HOTBAG_BIN` env var is passed in because a
  launchd agent's PATH is minimal.
- `indicator/install.sh` — `swiftc` build + `launchctl bootstrap` load;
  `uninstall` subcommand boots it out and removes the plist. Idempotent (boots
  out any prior instance before reloading). Logs to
  `~/.local/state/hot-bag/indicator.log`.

If you change what "on"/"wedged" mean, change it in `indicator_state()` in the
Bash script — NOT in the Swift, which must stay a dumb view.

State/logs live under `HOTBAG_HOME` (default `~/.local/state/hot-bag/`):
`watchdog.pid`, `caffeinate.pid`, `lidwatch.pid`, `chime.wav` (generated 8-bit
chime), `current-run` (path to active CSV), `disablesleep.on` (SLEEP_GUARD
marker), `.lock` (start/stop mutex), `runs/*.csv`.

## CSV schema

`epoch,iso,cpu_c,gpu_c,state,cpu_speed_limit,battery_pct,power_source,net_iface,net_status,rx_bytes,tx_bytes`

- `cpu_c`/`gpu_c`: float °C, or `NA` if smctemp missing/invalid.
- `state`: `OK|WARM|HOT|CRITICAL|THROTTLED`, derived by `thermal_state()`.
- `cpu_speed_limit`: from `pmset -g therm`; `100` when not throttling (default if
  the field is absent — Apple Silicon only populates it under load).
- `net_status`: `up|down` from a single ping.
- `rx_bytes`/`tx_bytes`: **cumulative** interface counters from `netstat -ibnI
  <dev>` (the `<Link` row, fields 7 and 10), i.e. bytes since that interface came
  up — NOT a per-sample delta. `read_iface_bytes()` reads them.

**Data-used accounting** (the `tether data` report line): per `net_iface`, take
`max(rx)-min(rx)` and `max(tx)-min(tx)` across that interface's samples, then sum
across interfaces. Grouping by interface keeps it correct across a USB↔Wi-Fi
failover (different interfaces have independent counters). Samples with a `0`
counter (read failure) are skipped so they don't poison the min. Caveat: an
interface bouncing down/up mid-run resets its counter and would under/over-count;
rare, not guarded. This measures *all* traffic over the link, not just Claude,
and is the Mac's view — a close proxy for the phone's tethered cellular use.

This logic exists in **two places** (keep them in sync if you change it): the
`report` END block (over the finished CSV) and the `run_data_used()` helper (used
by `status`, which folds in a live sample so the count reaches "now"). Bytes are
formatted by `human_bytes()`.

`report` is an awk one-liner over this CSV — if you change columns, update both
the writer in `_watch` and the awk field indices in `report`.

The report ends with a **verdict** block (also in awk) that picks a band from
the hottest sensor reading and prints contextual prose: temp interpretation,
throttle impact, network flakiness, battery drain, and an actionable next-time
suggestion. Bands inside the verdict are tighter than typical "desk normal"
numbers on purpose — in a sealed bag the constraint is airflow, not silicon,
so 80–90°C is "tight margin" rather than "fine." The throttle line uses the
`cpu_speed_limit` column as the authoritative signal (the `THROTTLED` state
label undercounts because it only fires when temps are otherwise OK). Two
constraints when editing the verdict awk: (a) it lives inside a single-quoted
shell string, so no apostrophes in the prose, and (b) ANSI codes use `\033`
which awk passes through verbatim.

## Telemetry sources & gotchas

- **CPU temp**: `smctemp -c -i25 -n40`. The retry flags are REQUIRED on Apple
  Silicon — a plain `smctemp -c` returns `0.0` and an error ("use -n/-i"). GPU
  (`smctemp -g`) reads fine without them but we pass them anyway for consistency.
  `smctemp` is from the third-party tap `narugit/tap`, installed `/opt/homebrew/bin`.
- **No degrees without smctemp.** There is no sudo-free built-in temp on Apple
  Silicon. `pmset -g therm` is the only no-install thermal signal and it's just a
  throttle flag, empty until the machine is actually throttling.
- **Battery/power**: parsed from `pmset -g batt` (`'AC Power'`/`'Battery Power'`
  in single quotes on line 1; percentage via `grep -Eo '[0-9]+%'`).
- **Active link**: `route -n get default | awk '/interface:/'`. `iface_label()`
  maps the `enX` device to its hardware-port name via `networksetup
  -listallhardwareports` (e.g. `iPhone USB`, `Wi-Fi`).
- **`netstat -ibnI <dev>` column positions are not stable across macOS releases.**
  `read_iface_bytes()` looks up the `Ibytes` / `Obytes` columns *by header name*
  rather than hardcoding indices. Don't regress this to `$7"/"$10`.

## Design decision: the watchdog is sudo-free

All telemetry readers avoid sudo on purpose, so the detached background loop runs
unattended without a cached-credential dependency (macOS `sudo` uses per-tty
tickets; a backgrounded process can't reliably reuse the foreground ticket, and
can't prompt). The only sudo calls are the foreground `pmset` in start/stop. If
you add a telemetry source that needs sudo (e.g. `powermetrics` thermal
pressure), do NOT call it per-sample in `_watch` — launch one long-lived
`sudo` stream from `start` (while the foreground ticket is fresh) and have
`_watch` read its output file. The lone exception is the optional
`LOW_BATT_ACTION=sleep` safety, which uses `sudo -n` and silently no-ops without
passwordless sudoers — acceptable because it's opt-in.

## Resilience model

- **Network**: macOS handles failover between simultaneously-connected links;
  the script only observes/logs. Active Wi-Fi rejoin (`networksetup
  -setairportnetwork`) fires only if `WIFI_SSID` is set and a sample is `down`.
- **Power**: works on battery by design; optional graceful-sleep safety prevents
  hard power-off. Default off so the job is never paused without consent.

## Testing without sudo

The whole telemetry path is testable without touching power settings:
```bash
INTERVAL=20 ./hot-bag _watch /tmp/hot-bag-test.csv &   # let it collect a few rows
kill %1
./hot-bag report /tmp/hot-bag-test.csv
./hot-bag status
```
Only `start`/`stop` need sudo (the `pmset` call). Avoid running those in a
non-interactive context — the password prompt will hang.

## Known limitations / future ideas

- No actual thermal-pressure level (Nominal/Fair/Serious/Critical) yet; would
  need the long-lived `sudo powermetrics` stream described above.
- Wi-Fi rejoin is best-effort and unverified per attempt.
- `report` assumes a well-formed CSV; a truncated last line (killed mid-write) is
  tolerated by awk but not explicitly guarded.
- Intel Macs: `disablesleep` exists but clamshell behavior differs; untested.
- **Bandwidth capping (`--cap RATE`, not yet built):** macOS has no per-process
  rate limit. The native path is `dnctl pipe N config bw <RATE>` + a *dedicated*
  pf anchor routing tether traffic into the pipe — load via `pfctl -a hot-bag
  -f -`, never edit `/etc/pf.conf`. Need separate pipes for up/down; scope with
  `dummynet out on <tether-dev>`. Must enable on start (`pfctl -E`) and fully
  tear down on stop (flush anchor + `dnctl -q flush`), with a trap so a crash
  doesn't strand a half-applied ruleset and drop the user's connection. Until
  then, the documented data-limiting answer is Low Data Mode (Wi-Fi tether only).
