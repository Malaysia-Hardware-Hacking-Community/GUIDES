#!/usr/bin/env python3
"""Drive a libvirt guest over its serial console, from the host, non-interactively.

Why this exists: the LFS guest in this project has no CONFIG_ACPI_BUTTON, so
`virsh shutdown` never completes -- the ACPI power-button event is never
delivered and nothing in the guest reacts to it. The only way to power the LFS
side down is to log in and run `systemctl poweroff`. Doing that by hand means
watching a terminal; doing it from a script needs a pty, because `virsh console`
detects a non-tty stdin and refuses to work.

Two subcommands:

  run       attach to an ALREADY RUNNING domain, run commands, optionally
            power off. (Uses `virsh console`, which needs the domain running.)

  capture   power the domain on with the console attached from the very first
            byte (`virsh start --console`), so GRUB and the kernel are captured
            too, then run commands and optionally power off.

Usage:

  console.py run --domain ubuntu-sandbox --password lfs \\
      --cmd 'uname -r' --cmd neofetch --poweroff

  console.py capture --domain ubuntu-sandbox --password lfs \\
      --log lfs/VERIFY-boot.log --cmd 'uname -r' --cmd neofetch --poweroff

Every byte read from the pty is written to the log verbatim, including the
kernel's own output. The log is the evidence; the summary printed at the end is
just a convenience.
"""
import argparse
import os
import pty
import random
import re
import select
import shutil
import signal
import subprocess
import sys
import time

PROMPT = re.compile(r"(?:^|\n)[^\n]*?[#\$]\s*$")
LOGIN = re.compile(r"login:\s*$", re.M)
PASSWORD_PROMPT = re.compile(r"[Pp]assword:\s*$")


class Session:
    """A virsh console attached to a pty, with a small expect-style driver."""

    def __init__(self, pid, master, log):
        self.pid = pid
        self.master = master
        self.log = log
        self.buf = b""
        self.closed = False

    def pump(self, seconds):
        """Read from the pty for `seconds`, appending everything to the log.

        Returns False once the pty is gone (guest powered off, or virsh died).
        """
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.master], [], [], 0.5)
            if not ready:
                continue
            try:
                data = os.read(self.master, 65536)
            except OSError:
                self.closed = True
                return False
            if not data:
                self.closed = True
                return False
            self.log.write(data)
            self.buf += data
            # Keep only a tail: a full kernel boot is ~80 KB and we only ever
            # match prompts against the most recent screenful.
            if len(self.buf) > 65536:
                self.buf = self.buf[-32768:]
        return True

    def text(self):
        return self.buf.decode("utf-8", "replace")

    def send(self, line):
        os.write(self.master, (line + "\n").encode())

    def wait_for(self, pattern, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if pattern.search(self.text()):
                return True
            if not self.pump(1.0):
                return False
        return False

    def virsh_error(self):
        """Return virsh's own error text if it printed one, else None.

        virsh writes failures to the pty, not to our stderr, so an attach
        failure is otherwise invisible until the login timeout expires. The
        caller uses this to abort immediately with the real reason.
        """
        m = re.search(r"^error:.*$", self.text(), re.M)
        return m.group(0).strip() if m else None

    def shell(self, user, password, timeout):
        """Reach an interactive shell, from either possible starting state.

        A serial line is one-shot, so this has to cope with two very different
        starting points that both look like "nothing is happening":

          (a) agetty already printed its prompt before we attached, so waiting
              for a fresh "login:" would hang forever;
          (b) a shell is already logged in (a previous session), so there is no
              login prompt to wait for and no new output to read.

        Strategy: nudge with empty lines for a couple of rounds (harmless at a
        shell, and makes agetty re-print its prompt), then fall through to
        probing with a marker command.

        The probe is `printf 'A%sB\\n' TOKEN` and the marker checked for is
        A<TOKEN>B. The token is inserted by printf at *runtime*, so the marker
        string cannot appear in the terminal's echo of the typed command -- a
        plain `echo TOKEN` would false-positive on its own echo whenever the
        line was typed at a password prompt and swallowed.
        """
        deadline = time.time() + timeout
        token = "%08x" % random.getrandbits(32)
        marker = f"A{token}B"
        probe = f"printf 'A%sB\\n' {token}"
        state = "nudge"
        rounds = 0
        last_send = 0.0
        while time.time() < deadline:
            text = self.text()
            if marker in text:
                return True
            if LOGIN.search(text) and state != "pass":
                self.send(user)
                state = "pass"
                self.buf = b""          # drop the stale "login:" we just matched
                last_send = time.time()
            elif PASSWORD_PROMPT.search(text) and state == "pass":
                self.send(password)
                state = "probe"
                self.buf = b""
                last_send = time.time()
            elif time.time() - last_send > 5:
                if state == "nudge":
                    self.send("")      # empty line: reprints an agetty prompt
                    rounds += 1
                    if rounds >= 2:
                        state = "probe"  # no login prompt appeared -> it's a shell
                else:
                    self.send(probe)
                last_send = time.time()
            if not self.pump(1.0):
                return False
        return False

    def run(self, cmd, timeout=180):
        """Run one command and wait for it to actually finish.

        Synchronises on a completion marker appended to the command rather than
        on the shell prompt. The prompt is unreliable here: it was printed once
        when the session started and is never re-emitted, so waiting for it
        burns the whole timeout on every command (and, with several commands,
        the caller gets killed before it ever reaches the poweroff). Appending
        a printf marker gives a definite end-of-command signal.

        The marker is inserted by printf at runtime, so it cannot match the
        terminal's echo of the typed line. Do not use `echo TOKEN` for this.
        """
        token = "%08x" % random.getrandbits(32)
        self.send(f"{cmd}; printf 'A%sB\\n' {token}")
        return self.wait_for(re.compile(re.escape(f"A{token}B")), timeout)

    def close(self):
        try:
            os.write(self.master, b"\x03")
        except OSError:
            pass
        time.sleep(0.3)
        try:
            self.log.close()
        except OSError:
            pass
        try:
            os.close(self.master)
        except OSError:
            pass
        # Reap the child. SIGHUP first so virsh gets a chance to exit on its
        # own; SIGKILL only if it is still hanging around.
        for sig, wait in ((signal.SIGHUP, 5), (signal.SIGKILL, 5)):
            try:
                done, _ = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                return
            if done:
                return
            try:
                os.kill(self.pid, sig)
            except ProcessLookupError:
                return
            time.sleep(0.5)


def open_session(argv, env):
    """Spawn `virsh ...` on a fresh pty and return a Session.

    pty.fork(), not pty.openpty(): `virsh console` refuses to attach unless
    stdin is a *controlling* terminal, and openpty() only gives us a pty pair --
    it does not run setsid()+TIOCSCTTY. Without the controlling terminal virsh
    prints "Cannot run interactive console without a controlling TTY" and
    exits, which used to look like this script hanging until its timeout.
    pty.fork() makes the child's slave pty its controlling terminal before exec.
    """
    pid, master = pty.fork()
    if pid == 0:
        # Child: stdin/stdout/stderr are already the slave, and it is the ctty.
        try:
            os.close(master)
        except OSError:
            pass
        try:
            os.execvpe(argv[0], argv, env)
        finally:
            os._exit(127)
    log = open(env["CAPLOG"], "wb", buffering=0)
    return Session(pid, master, log)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["run", "capture"])
    ap.add_argument("--uri", default="qemu:///session")
    ap.add_argument("--domain", required=True)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="lfs")
    ap.add_argument("--cmd", action="append", default=[],
                    help="command to run after login; repeatable")
    ap.add_argument("--poweroff", action="store_true",
                    help="run 'systemctl poweroff' at the end and wait for exit")
    ap.add_argument("--log", help="log path (default /tmp/console-<domain>.log)")
    ap.add_argument("--timeout", type=int, default=300)
    args = ap.parse_args()

    virsh = shutil.which("virsh")
    if not virsh:
        sys.exit("virsh not found in PATH")

    log = args.log or f"/tmp/console-{args.domain}.log"
    env = {**os.environ, "TERM": "dumb", "CAPLOG": log}

    if args.mode == "run":
        # Needs the domain already running. `virsh console` refuses a non-tty
        # stdin, which is exactly why this script exists.
        state = subprocess.run(
            [virsh, "-c", args.uri, "domstate", args.domain],
            capture_output=True, text=True,
        ).stdout.strip().lower()
        if "running" not in state:
            sys.exit(f"{args.domain} is {state!r}, not running; use `capture`")

    argv = [virsh, "-c", args.uri]
    argv += ["console", args.domain] if args.mode == "run" else \
            ["start", args.domain, "--console"]

    session = open_session(argv, env)
    try:
        if not session.shell(args.user, args.password, args.timeout):
            # Surface virsh's own complaint rather than a bare "could not log
            # in", which is what made the earlier failure look like a hang.
            err = session.virsh_error()
            session.close()
            if err:
                sys.exit(f"{args.domain}: {err}\n  (see {log})")
            sys.exit(f"could not log in to {args.domain}; see {log}")
        for cmd in args.cmd:
            if not session.run(cmd):
                warn(f"command may not have completed: {cmd}")
        if args.poweroff:
            # No marker to wait for: powering off tears the pty down, and that
            # pty closing IS the success signal. sync first so the guest
            # filesystem is clean before the power goes.
            session.send("sync")
            session.pump(3.0)
            session.send("systemctl poweroff")
            deadline = time.time() + 90
            while time.time() < deadline and not session.closed:
                session.pump(2.0)
            print(f"poweroff sent; pty closed: "
                  f"{'yes' if session.closed else 'NO'}")
    finally:
        session.close()

    raw = open(log, "rb").read().decode("utf-8", "replace")
    print(f"log: {log}")
    print(f"captured bytes: {len(raw)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
