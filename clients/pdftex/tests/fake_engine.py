"""A fake live pdfTeX engine for the driver's tests (GPL-2.0-or-later, like the rest of clients/pdftex).

It speaks the engine's side of the driver protocol (clients/pdftex/README.md, "Messages") with real fork snapshots,
the way lib/taudot-live.c does: before a line of a project file, at most every TAUDOT_SNAPSHOT_MS, the runner forks;
the parent waits as the snapshot; when the driver SIGKILLs the snapshot's child, the snapshot forks a new runner that
reloads the project files, reads OUT/ctl and sends R. When the driver retires the child (SIGTERM, a snapshot thinned
out of its table), the snapshot waits childless until SIGUSR1 wakes it the same way. A snapshot whose child dies
otherwise sends X and exits.

The "document" is text: each line is read as TeX would read it. Special lines:
    \\input{FILE}   read FILE (a project file) here; a missing one logs "No file FILE."
    \\aux{TEXT}     write TEXT as a line of the job's .aux
    \\write{F}{TEXT} write TEXT as a line of the project file F (an \\include'd chapter's .aux)
    \\fatal         stop with an error (code 1); no PDF if no page was shipped
    \\crash         the runner dies of SIGSEGV (pdfTeX crashing)
Every FAKE_LINES_PER_PAGE lines read ship a page.

Knobs (environment): FAKE_LINE_MS (time per line, default 1), FAKE_R_DELAY_MS (before a resumed runner sends R),
FAKE_LINES_PER_PAGE (default 4), FAKE_LOG (a file the engine appends its pid and events to), FAKE_START_MS (between
reading ctl at start and the first line), FAKE_NO_RETIRE (an engine without patch 0010).
"""
import os
import signal
import socket
import sys
import time


def now_us():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1000


ENV = os.environ
FD = int(ENV["TAUDOT_LIVE_FD"])
PROJ = os.path.realpath(ENV.get("TAUDOT_PROJECT", "."))
OUT = ENV.get("TAUDOT_LIVE_OUT", ".")
SNAP_US = int(float(ENV.get("TAUDOT_SNAPSHOT_MS", "50")) * 1000)
LINE_S = float(ENV.get("FAKE_LINE_MS", "1")) / 1000
R_DELAY_S = float(ENV.get("FAKE_R_DELAY_MS", "0")) / 1000
LINES_PER_PAGE = int(ENV.get("FAKE_LINES_PER_PAGE", "4"))
LOG = ENV.get("FAKE_LOG")
sock = socket.socket(fileno=FD)

driver = os.getppid()
parent = driver
seq = 0
watch_rel, watch_off = "-", -1
goal, goal_done = -1, False
want_ctl = False
pages = 0
lines_read = 0
last_snap = 0
want_finish = False
files = {}       # rel -> bytes, as loaded
tracks = {}      # rel -> [extent, opened]
stack = []       # [rel, pos]
aux = []
writes = {}      # rel -> lines written (\write)
typeset = []     # the lines read, in order: what the PDF shows
log = []
main = None


def note(msg):
    if LOG:
        with open(LOG, "a") as f:
            f.write(f"{os.getpid()} {msg}\n")


def send(msg):
    try:
        sock.send(msg.encode())
    except OSError:
        pass


def load(rel):
    try:
        with open(os.path.join(PROJ, rel), "rb") as f:
            return f.read()
    except OSError:
        return None


def read_ctl(goal_only=False):
    global seq, watch_rel, watch_off, goal, goal_done
    try:
        with open(os.path.join(OUT, "ctl")) as f:
            p = f.read().split()
    except OSError:
        return
    if len(p) >= 3 and not goal_only:
        seq, watch_off, watch_rel = int(p[0]), int(p[1]), p[2]
    if len(p) >= 5:
        if int(p[3]) != goal:
            goal_done = False
        goal = int(p[3])


def dump(name, data):
    tmp = os.path.join(OUT, name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(data)
    os.rename(tmp, os.path.join(OUT, name))


def pdf_bytes():
    return b"%PDF-1.4 fake\n" + f"pages {pages} seq {seq}\n".encode() + b"".join(typeset)


def finish():
    t0 = now_us()
    if os.fork() == 0:
        if os.fork():  # double fork, as the engine's: the finisher outlives a runner killed meanwhile
            os._exit(0)
        time.sleep(float(ENV.get("FAKE_FINISH_MS", "0")) / 1000)
        name = f"pdf-{seq}-{os.getpid()}"
        dump(name + ".pdf", pdf_bytes())
        dump(name + ".log", "\n".join(log).encode() + b"\n")
        t = now_us()
        send(f"P {os.getpid()} {seq} {pages} {t0} {t0} {t} {t} {name}.pdf\n")
        os._exit(0)
    os.wait()


def on_usr1(sig, frame):
    global want_finish
    want_finish = True


def driver_gone():
    try:
        os.kill(driver, 0)
        return False
    except ProcessLookupError:
        return True

def on_usr2(sig, frame):
    global want_ctl
    want_ctl = True


def be_snapshot(child):
    """The parent side of a fork: wait; on SIGKILL of the child (or SIGUSR1 once the child was retired), fork a new
    runner and return in it."""
    global parent, last_snap, want_finish, goal_done
    want_finish = False  # from now on SIGUSR1 means "wake"
    while True:
        while child:
            try:
                pid, st = os.waitpid(child, os.WNOHANG)
            except ChildProcessError:
                os._exit(3)
            if pid:
                if os.WIFSIGNALED(st) and os.WTERMSIG(st) == signal.SIGKILL:
                    break
                if os.WIFSIGNALED(st) and os.WTERMSIG(st) == signal.SIGTERM:
                    note("childless")
                    child = 0
                    break
                send(f"X {os.getpid()} {child} {st}\n")
                os._exit(3)
            if driver_gone():
                os.kill(child, signal.SIGKILL)
                os._exit(0)
            time.sleep(0.002)
        while not child and not want_finish:
            if driver_gone():
                os._exit(0)
            time.sleep(0.002)
        if not child:
            note("woken")
        want_finish = False
        c = os.fork()
        if c == 0:
            parent = os.getppid()
            for r in list(files):
                b = load(r)
                if b is not None:
                    files[r] = b
            want_finish = False
            goal_done = False
            read_ctl()
            last_snap = now_us()
            if R_DELAY_S:
                time.sleep(R_DELAY_S)
            note(f"R seq {seq}")
            send(f"R {os.getppid()} {os.getpid()} {seq} {last_snap}\n")
            return
        child = c


def snapshot():
    global parent, last_snap
    t = now_us()
    c = os.fork()
    if c == 0:
        parent = os.getppid()
        last_snap = t
        body = "".join(f"{e[0]} {r}\n" for r, e in tracks.items())
        send(f"S {os.getppid()} {os.getpid()} {t} {len(tracks)} {pages}\n{body}")
        return
    be_snapshot(c)


def before_line():
    global want_ctl
    if os.getppid() != parent:
        os._exit(0)  # a stale runner
    if want_ctl:
        want_ctl = False
        read_ctl(goal_only=True)
    if want_finish:
        finish_now()
    if ENV.get("FAKE_NO_SNAP"):  # a run that never snapshots (C13)
        return
    if not last_snap or now_us() - last_snap >= SNAP_US:
        snapshot()


def finish_now():
    global want_finish
    want_finish = False
    if pages:
        finish()


def open_file(rel):
    b = load(rel)
    tracks.setdefault(rel, [0, 1])
    if b is None:
        log.append(f"No file {rel}.")
        return False
    files[rel] = b
    stack.append([rel, 0])
    return True


def end(code):
    if pages:
        dump(f"final-{seq}.pdf", pdf_bytes())
    dump(f"final-{seq}.log", "\n".join(log).encode() + b"\n")
    w = os.path.join(OUT, f"w-{seq}")
    os.makedirs(w, exist_ok=True)
    job = os.path.splitext(main)[0]
    dump(f"w-{seq}/{job}.aux", "".join(a + "\n" for a in aux).encode())
    for rel, lines in writes.items():
        dump(f"w-{seq}/{rel.replace('/', '%2F')}", "".join(a + "\n" for a in lines).encode())
    body = "".join(f"{e[0]} {e[1]} {r}\n" for r, e in tracks.items())
    send(f"T {os.getpid()} {seq} {len(tracks)}\n{body}")
    send(f"E {os.getpid()} {seq} {pages} {code} {now_us()}\n")
    note(f"E seq {seq} pages {pages} code {code}")
    while True:  # stay until our snapshot or the driver goes
        if os.getppid() != parent:
            os._exit(0)
        try:
            os.kill(driver, 0)
        except ProcessLookupError:
            os._exit(0)
        time.sleep(0.01)


def run():
    global pages, lines_read, goal_done
    while stack:
        rel, pos = stack[-1]
        buf = files[rel]
        if pos >= len(buf):
            tracks[rel][0] = len(buf) + 1  # saw the end
            stack.pop()
            continue
        before_line()
        rel, pos = stack[-1]
        buf = files[rel]  # reloaded by a resume
        if pos >= len(buf):
            continue
        nl = buf.find(b"\n", pos)
        e = len(buf) if nl < 0 else nl + 1
        typeset.append(buf[pos:e])
        line = buf[pos:e].decode("utf-8", "replace").strip()
        stack[-1][1] = e
        tracks[rel][0] = max(tracks[rel][0], e)
        if LINE_S:
            time.sleep(LINE_S)
        lines_read += 1
        if line.startswith("\\input{") and line.endswith("}"):
            open_file(line[7:-1])
        elif line.startswith("\\aux{") and line.endswith("}"):
            aux.append(line[5:-1])
        elif line.startswith("\\write{") and "}{" in line and line.endswith("}"):
            f, _, t = line[7:-1].partition("}{")
            writes.setdefault(f, []).append(t)
        elif line == "\\crash":
            os.kill(os.getpid(), signal.SIGSEGV)
        elif line == "\\fatal":
            log.append("! Emergency stop.")
            end(1)
        if lines_read % LINES_PER_PAGE == 0:
            pages += 1
            send(f"p {os.getpid()} {pages} {now_us()}\n")
            if goal >= 0 and not goal_done and pages > goal:  # the goal page shipped: a PDF now (patch 0009)
                goal_done = True
                finish()
    end(0)


if __name__ == "__main__":
    signal.signal(signal.SIGUSR1, on_usr1)
    signal.signal(signal.SIGUSR2, on_usr2)
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    main = args[-1]
    note("start")
    read_ctl()
    if not ENV.get("FAKE_NO_RETIRE"):
        send("V 1 retire\n")
    time.sleep(float(ENV.get("FAKE_START_MS", "0")) / 1000)  # read ctl, not yet a snapshot
    if not open_file(main):
        log.append("! I can't find file.")
        end(1)
    run()
