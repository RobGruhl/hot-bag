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
  spawn `caffeinate`, spawn the watchdog detached via `nohup "$0" _watch <log> &`.
- `stop` — `disablesleep 0` (non-fatal on failure), kill watchdog + caffeinate
  via `safe_ps_match`, sweep any stragglers with `pkill -f "$0 _watch"`, then
  `report`. Exits non-zero if the restore step failed so the user notices.
- `status` — one-shot live reading (no sudo, no side effects). When a run is
  active (watchdog pid alive + `current-run` present), it also prints `data this
  run` by folding the live byte counters into `run_data_used()`. Warns loudly
  if the sleep override is on but no watchdog is running (wedged state).
- `report [logfile]` — summarize a CSV (defaults to current/latest run).
- `doctor` — recovery: restore `disablesleep 0` if it's on, sweep stale
  `_watch`/`caffeinate` processes, remove stale pid/lock/state files. Safe to
  run any time.
- `_watch <logfile>` — **internal**; the background sampling loop. Re-enters the
  same script so config flows in via exported env vars from `start`.

State/logs live under `HOTBAG_HOME` (default `~/.local/state/hot-bag/`):
`watchdog.pid`, `caffeinate.pid`, `menubar.pid`, `current-run` (path to active
CSV), `disablesleep.on` (SLEEP_GUARD marker), `.lock` (start/stop mutex),
`hot-bag-menubar` (compiled 🔥 helper), `runs/*.csv`.

## Menu-bar flame indicator

`start` shows a 🔥 in the macOS status bar for the duration of a run; `stop`
and `doctor` remove it. Implementation: a tiny Swift `NSStatusItem` app whose
source is embedded in the script as a heredoc (`menubar_build`), compiled once
with `swiftc` (Xcode CLT) to `$HOTBAG_HOME/hot-bag-menubar`, and rebuilt when
the script is newer than the binary (`$0 -nt` — follows the install symlink to
the real file). Invariants:

- **Optional by design.** No `swiftc`, compile failure, or `MENUBAR=0` must
  never block `start` — `menubar_start` warns and returns 0. Don't make the
  flame load-bearing.
- **The helper self-terminates.** It gets the watchdog pid as argv[1] and
  polls `kill(pid, 0)` every 5s, exiting when the watchdog is gone — so a
  crashed run can't strand a stale flame even if `stop`/`doctor` never run.
  Don't drop that argument.
- Kills go through `safe_ps_match` on the pidfile plus a `pkill -f
  "$MENUBAR_BIN"` stray sweep — safe because the binary path is unique to
  hot-bag's state dir.
- The Swift heredoc is quoted (`<<'SWIFT'`) so `$`/backticks in Swift are
  literal. Keep it that way.

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
