#!/usr/bin/env python3
"""Safe Linux/macOS PTY checks; all system probes stubbed, no power changes."""
import fcntl, os, pty, select, signal, struct, subprocess, tempfile, termios, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def resize(fd, size):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", *size, 0, 0))
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    bin = tmp / "bin"; bin.mkdir()
    (bin / "pmset").write_text('#!/bin/sh\necho "SleepDisabled 0"\n')
    (bin / "pmset").chmod(0o755)
    env = dict(os.environ, HOME=str(tmp), HOTBAG_HOME=str(tmp / "state"),
               TERM="xterm-256color", PATH=str(bin)+":"+os.environ["PATH"])
    cli = [str(ROOT / "hot-bag"), "screensaver", "--terminal"]
    r = subprocess.run(cli, env=env, capture_output=True)
    assert r.returncode == 2 and b"interactive ANSI" in r.stderr
    for mode, key, sig in [
        ("off", b'q', None), ("off", b'\x1b', None),
        ("off", b'', signal.SIGTERM), ("off", b'', signal.SIGINT),
        ("off", b'', signal.SIGHUP), ("off", b'', signal.SIGTSTP),
        ("on", b'q', None),
        ("wedged", b'q', None), ("corrupt", b'q', None),
    ]:
        state = tmp / "state"; state.mkdir(exist_ok=True)
        (bin / "pmset").write_text('#!/bin/sh\necho "SleepDisabled ' + ('0' if mode == 'off' else '1') + '"\n')
        (bin / "ps").write_text('#!/bin/sh\necho hot-bag _watch\n')
        (bin / "ps").chmod(0o755)
        pidfile = state / "watchdog.pid"
        pidfile.write_text(str(os.getpid()) if mode in ("on", "corrupt") else "99999999")
        logfile = state / "fixture.csv"
        logfile.write_text(str(int(time.time())) + ",iso,57.1,54.0,OK,100,82,Battery Power,en0,up,100,200\n")
        if mode == "corrupt":
            logfile.write_text(str(int(time.time())) + ",iso,\x1b[31mBAD,54,OK,100,82,Battery Power,en0,up,100,200\n")
        (state / "current-run").write_text(str(logfile))

        master, slave = pty.openpty()
        resize(slave, (24, 80))
        before = termios.tcgetattr(slave)
        proc = subprocess.Popen(cli, env=env, stdin=slave, stdout=slave, stderr=slave)
        out = b""
        deadline = time.time()+3
        while time.time()<deadline and b"Sleep settings unchanged." not in out:
            if select.select([master], [], [], .2)[0]: out += os.read(master, 65536)
        assert b"F L Y I N G   T O A S T E R" in out, out
        if mode == "off": assert b"RUN OFF / preview only" in out, out
        elif mode == "wedged": assert b"WEDGED!" in out, out
        else: assert b"RUN ACTIVE" in out, out
        if mode == "on": assert b"CPU 57.1C GPU 54.0C BATT 82%" in out, out
        else: assert b"No complete telemetry" in out, out
        assert b"BAD" not in out

        # Resize tiny, then enlarge: must remain usable and restore settings.
        resize(slave, (4, 18))
        proc.send_signal(signal.SIGWINCH)
        time.sleep(1.1)
        resize(slave, (30, 100))
        proc.send_signal(signal.SIGWINCH)
        if sig: proc.send_signal(sig)
        else: os.write(master, key)
        # Drain PTY while waiting: macOS has a small output buffer.
        deadline = time.time() + 4
        while proc.poll() is None and time.time() < deadline:
            if select.select([master], [], [], .1)[0]: out += os.read(master, 65536)
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill(); proc.wait()
            raise
        while select.select([master], [], [], .1)[0]: out += os.read(master, 65536)
        assert b"\x1b[?1049l" in out and b"\x1b[?25h" in out, (proc.returncode, out[-500:])
        after = termios.tcgetattr(slave)
        # Darwin toggles PENDIN internally when restoring canonical input.
        after[3] &= ~getattr(termios, "PENDIN", 0)
        before[3] &= ~getattr(termios, "PENDIN", 0)
        assert after == before
        assert proc.returncode == ({signal.SIGTERM: 143, signal.SIGINT: 130, signal.SIGHUP: 129, signal.SIGTSTP: 0}.get(sig, 0)), proc.returncode
        assert not (tmp / "state/disablesleep.on").exists()
        os.close(master); os.close(slave)
print("PASS: non-TTY; q/Esc/INT/TERM/HUP/TSTP cleanup; resize; off/active/wedged; cached/corrupt CSV; no sleep guard")
