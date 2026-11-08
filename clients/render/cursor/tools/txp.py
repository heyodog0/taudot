"""Drive txp-render from Python: typeset a document, then ask for glyphs, SyncTeX, renders.

    uv run clients/render/cursor/tools/txp.py DIR/main.tex OUTDIR   # glyphs of every page + SyncTeX, timings
"""
import json, os, select, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "..", "txp-render")


class Txp:
    def __init__(self, tex, log=None):
        self.p = subprocess.Popen([BIN, tex], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=log or subprocess.DEVNULL, bufsize=0)
        self.buf = b""
        self.next_id = 1
        self.pages = None

    def send(self, cmd):
        self.p.stdin.write((json.dumps(cmd) + "\n").encode())

    def read(self, timeout):
        while b"\n" not in self.buf:
            r, _, _ = select.select([self.p.stdout], [], [], timeout)
            if not r:
                return None
            chunk = os.read(self.p.stdout.fileno(), 1 << 16)
            if not chunk:
                raise EOFError("txp-render exited")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def settle(self, quiet=4.0, limit=300):
        """Wait for the finished document, then until no report comes for `quiet` s (aux reruns)."""
        t0 = time.time()
        done = False
        while time.time() - t0 < limit:
            ev = self.read(quiet if done else limit)
            if ev is None:
                if done:
                    return self.pages
                continue
            if ev.get("ev") == "pages":
                self.pages = ev
                done = ev["done"]
        raise TimeoutError("document didn't settle")

    def call(self, verb, *args):
        i = self.next_id
        self.next_id += 1
        self.send([verb, i, *args])
        while True:
            ev = self.read(120)
            if ev is None:
                raise TimeoutError(verb)
            if ev.get("id") == i or ("id" not in ev and ev.get("ok") is False):
                return ev
            if ev.get("ev") == "pages":
                self.pages = ev

    def close(self):
        self.p.stdin.close()
        self.p.wait(10)


def main():
    tex, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    t = Txp(tex)
    t0 = time.time()
    pages = t.settle()
    print(f"typeset {pages['n']} pages in {time.time() - t0:.1f} s")
    print("synctex", t.call("synctex", os.path.abspath(os.path.join(outdir, "main.synctex"))))
    us = []
    for p in range(pages["n"]):
        r = t.call("glyphs", p, os.path.abspath(os.path.join(outdir, f"glyphs-{p}.json")))
        us.append(r["us"])
        print(p, r)
    us2 = [t.call("glyphs", p, "/dev/null")["us"] for p in range(pages["n"])]
    print(f"glyphs: first call median {sorted(us)[len(us)//2]} us max {max(us)}; "
          f"cached display list median {sorted(us2)[len(us2)//2]} us max {max(us2)}")
    t.close()


if __name__ == "__main__":
    main()
