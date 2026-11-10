# MIT. tau-tdl `page` takes the page's content stream from what the engine wrote for the page, and nothing else: a
# font program written at the same ship (an embedded figure's fonts) has no /Type, may hold "BT" and stray ')' bytes,
# and once was taken as the content (a display page drawing garbage) or hung the reader.
#   uv run --no-project --with pikepdf clients/universal/tests/pagepick.py EXACT.pdf PAGE   (UBIN: tau-tdl's directory)
import os, subprocess, sys, tempfile, zlib
import pikepdf

exact, k = sys.argv[1], int(sys.argv[2])
with pikepdf.open(exact) as pdf:
    c = pdf.pages[k].Contents
    content = b"".join(x.read_bytes() for x in c) if isinstance(c, pikepdf.Array) else c.read_bytes()
new = content + b"\n"  # (a changed page: else `same`)
z = zlib.compress(new)
font = zlib.compress(b"\x00BT)\x00(" * 50 + b") ) BT ET")  # a "font program": BT and stray parentheses
data = (b"7 0 obj\n<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(z) + z + b"\nendstream\nendobj\n" +
        b"8 0 obj\n<< /Length1 300 /Length2 0 /Length3 0 /Length %d /Filter /FlateDecode >>\nstream\n" % len(font) +
        font + b"\nendstream\nendobj\n")
d = tempfile.mkdtemp()
open(f"{d}/page.bin", "wb").write(data)
r = subprocess.run([f"{os.environ['UBIN']}/tau-tdl", "serve"], input=f"page\t{exact}\t{k}\t{d}/page.bin\t{d}/out.pdf\n",
                   capture_output=True, text=True, timeout=10)
ans = r.stdout.strip()
ok = '"ok":true' in ans
if ok:
    with pikepdf.open(f"{d}/out.pdf") as out:
        c = out.pages[k].Contents
        got = b"".join(x.read_bytes() for x in c) if isinstance(c, pikepdf.Array) else c.read_bytes()
    ok = got == new
print(f"pagepick: {ans}; the display page draws the page's content stream: {ok}")
sys.exit(0 if ok else 1)
