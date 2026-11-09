# MIT. tau-pdfmx (resident xdvipdfmx) against stock xdvipdfmx: every output byte-identical, and the time per request.
#   uv run --no-project clients/universal/tests/pdfmx.py DOC.xdv [N]
# N random page ranges as the app asks for them (`-q -z 1 -s FIRST-LAST`: from an edited page to the end, or one
# page), each converted by a fresh `xdvipdfmx` and by one `tau-pdfmx serve`, compared byte for byte. Environment:
# clients/universal/env.sh. Outputs go next to DOC (a scratch copy).
import os
import random
import statistics
import subprocess
import sys
import time

UBIN = os.environ["UBIN"]
xdv = os.path.abspath(sys.argv[1])
n = int(sys.argv[2]) if len(sys.argv) > 2 else 20
d = os.path.dirname(xdv)


def pages(path):
    """Page count from the postamble (DVI: post_post's pointer → post, whose last 2 bytes before fonts are the count)."""
    b = open(path, "rb").read()
    i = len(b) - 1
    while b[i] == 223:
        i -= 1
    post = int.from_bytes(b[i - 4:i], "big")
    return int.from_bytes(b[post + 27:post + 29], "big")


npages = pages(xdv)
random.seed(int(os.environ.get("SEED", "1")))
reqs = []
for k in range(n):
    first = random.randrange(npages)
    last = npages - 1 if k % 2 == 0 else first
    reqs.append((first, last))

srv = subprocess.Popen([f"{UBIN}/tau-pdfmx", "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
time.sleep(0.5)  # warm-up happens before the first request; the app starts the server with the session
stock_ms, srv_ms, srv_us, same = [], [], [], 0
for k, (first, last) in enumerate(reqs):
    s = f"{first + 1}-{last + 1}"
    # the same output name for both: xdvipdfmx's font subset tags hash it
    a, b = f"{d}/stock-{k}.pdf", f"{d}/out-{k}.pdf"
    t = time.monotonic()
    subprocess.run([f"{UBIN}/xdvipdfmx", "-q", "-z", "1", "-s", s, "-o", b, xdv], cwd=d, check=True)
    stock_ms.append((time.monotonic() - t) * 1000)
    os.rename(b, a)
    t = time.monotonic()
    srv.stdin.write("\t".join([d, "-q", "-z", "1", "-s", s, "-o", b, xdv]) + "\n")
    srv.stdin.flush()
    ans = srv.stdout.readline().split()
    srv_ms.append((time.monotonic() - t) * 1000)
    srv_us.append(int(ans[2]))
    eq = ans[1] == "0" and open(a, "rb").read() == open(b, "rb").read()
    same += eq
    print(f"{s:>7} stock {stock_ms[-1]:6.1f} ms  server {srv_ms[-1]:6.1f} ms  {'same' if eq else 'DIFFERENT'}")
    os.remove(a)
    if eq:
        os.remove(b)
srv.stdin.close()
srv.wait()


def q(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * len(v)))]


for name, sel in (("one page", 1), ("to the end", 0)):
    idx = [i for i, (f, l) in enumerate(reqs) if (f == l) == bool(sel)]
    st, sv = [stock_ms[i] for i in idx], [srv_ms[i] for i in idx]
    if idx:
        print(f"{name}: stock p50 {statistics.median(st):.1f} p90 {q(st, .9):.1f} ms; "
              f"server p50 {statistics.median(sv):.1f} p90 {q(sv, .9):.1f} ms ({len(idx)})")
print(f"identical {same}/{n}")
sys.exit(0 if same == n else 1)
