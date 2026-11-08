# Builds the bundle font index (patch 0005): for every OTF/TTF/TTC in the Tectonic bundle, the names and style data
# XeTeX's font manager reads (as TeX Live's fontconfig build does), without downloading the fonts. Our own code (MIT).
#
#   uv run clients/render/texpresso/fonts/make_index.py BUNDLE.index DIGEST OUT.c [--url URL] [--limit N]
#
# BUNDLE.index is Tectonic's cached index of the bundle tar (`<cache>/bundles/data/<digest>.index`: name, offset,
# length per file); DIGEST is the bundle's SHA256SUM. For each font it fetches, with HTTP Range requests: the sfnt
# header and table directory, then only `name`, `OS/2` (first 64 bytes), `head` (first 54), `post` (first 8) and,
# from `GPOS`, the header, FeatureList and the `size` feature's parameters. At most 4 requests at a time, a plain
# User-Agent, retries with backoff; it stops (exit 3) past 50 MB rather than fetch more.
import concurrent.futures as cf
import struct
import sys
import threading
import time
import urllib.error
import urllib.request

UA = "Taudot-font-index/0.1 (renderer engine; one-time font name index)"
DEFAULT_URL = "https://relay.fullyjustified.net/default_bundle_v33.tar"
LIMIT = 50 * 1000 * 1000
lock = threading.Lock()
fetched = 0
requests = 0


class TooMuch(Exception):
    pass


def resolve(url):
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.geturl()


def get(url, start, n):
    """Bytes [start, start+n) of the tar, by Range; insists on a 206."""
    global fetched, requests
    if n <= 0:
        return b""
    with lock:
        if fetched + n > LIMIT:
            raise TooMuch(f"would exceed {LIMIT} bytes")
        fetched += n
        requests += 1
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Range": f"bytes={start}-{start + n - 1}"})
            with urllib.request.urlopen(req, timeout=60) as r:
                if r.status != 206:
                    raise TooMuch(f"server answered {r.status} to a Range request")
                data = r.read()
            if len(data) != n:
                raise IOError(f"short read {len(data)} of {n}")
            return data
        except TooMuch:
            raise
        except (urllib.error.URLError, IOError, TimeoutError) as e:
            if isinstance(e, urllib.error.HTTPError) and e.code not in (429, 500, 502, 503, 504, 520, 521, 522, 523, 524):
                raise
            time.sleep(min(60, 2 ** attempt))
    raise IOError(f"giving up on {start}+{n}")


def u16(b, o): return struct.unpack_from(">H", b, o)[0]
def i16(b, o): return struct.unpack_from(">h", b, o)[0]
def u32(b, o): return struct.unpack_from(">I", b, o)[0]
def i32(b, o): return struct.unpack_from(">i", b, o)[0]


def names_like_fontconfig_xetex(name):
    """XeTeX's XeTeXFontMgr_FC::readNames over a `name` table: IDs 4 (full), 1 (family), 2 (style), 16, 17. Mac Roman
    English records are put first, Unicode/Microsoft ones appended in table order, duplicates dropped; 16 and 17,
    when present, replace 1 and 2. Also the PostScript name (ID 6)."""
    lists = {1: [], 2: [], 4: [], 16: [], 17: []}
    ps = {}
    if len(name) < 6:
        return lists, ""
    count, strings = u16(name, 2), u16(name, 4)
    for k in range(count):
        o = 6 + 12 * k
        if o + 12 > len(name):
            break
        plat, enc, lang, nid, ln, off = struct.unpack_from(">6H", name, o)
        raw = name[strings + off:strings + off + ln]
        if nid == 6:
            if plat == 3 and lang == 0x409:
                ps.setdefault(0, raw.decode("utf-16-be", "replace"))
            elif plat == 1 and enc == 0 and lang == 0:
                ps.setdefault(1, raw.decode("mac_roman", "replace"))
            elif plat in (0, 3):
                ps.setdefault(2, raw.decode("utf-16-be", "replace"))
            continue
        if nid not in lists:
            continue
        if plat == 1 and enc == 0 and lang == 0:
            s, first = raw.decode("mac_roman", "replace"), True
        elif plat in (0, 3):
            s, first = raw.decode("utf-16-be", "replace"), False
        else:
            continue
        lst = lists[nid]
        if s in lst:
            continue
        lst.insert(0, s) if first else lst.append(s)
    fam = lists[16] or lists[1]
    sty = lists[17] or lists[2]
    return {"full": lists[4], "family": fam, "style": sty}, ps.get(0) or ps.get(1) or ps.get(2) or ""


class Blob:
    """Bytes of one font file fetched so far: ranges merged into few requests, more fetched on demand."""

    def __init__(self, url, base, length):
        self.url, self.base, self.length, self.parts = url, base, length, []

    def prefetch(self, ranges, gap=4096):
        ranges = sorted((o, min(o + n, self.length)) for o, n in ranges if n > 0 and o < self.length)
        merged = []
        for a, b in ranges:
            if merged and a - merged[-1][1] <= gap:
                merged[-1][1] = max(merged[-1][1], b)
            else:
                merged.append([a, b])
        for a, b in merged:
            self.parts.append((a, get(self.url, self.base + a, b - a)))

    def read(self, off, n):
        n = max(0, min(n, self.length - off))
        for a, data in self.parts:
            if a <= off and off + n <= a + len(data):
                return data[off - a:off - a + n]
        data = get(self.url, self.base + off, n)
        self.parts.append((off, data))
        return data


def size_params(blob, gpos_off, gpos_len):
    """HarfBuzz's hb_ot_layout_get_size_params: the first `size` feature whose parameters sanitise (designSize > 0;
    all-zero subfamily/range, or design within the range and a name ID in 256..32767). Parameters are looked for at
    the Feature table's offset and, failing that, relative to the FeatureList (old Adobe fonts)."""
    if gpos_len < 10:
        return None
    fl = u16(blob.read(gpos_off, 10), 6)
    if not fl or fl + 2 > gpos_len:
        return None
    n = u16(blob.read(gpos_off + fl, 2), 0)
    recs = blob.read(gpos_off + fl + 2, 6 * n) if n else b""
    for k in range(n):
        if recs[6 * k:6 * k + 4] != b"size":
            continue
        foff = fl + u16(recs, 6 * k + 4)
        poff = u16(blob.read(gpos_off + foff, 2), 0)
        if not poff:
            continue
        for at in (foff + poff, fl + poff):
            if at + 10 > gpos_len:
                continue
            d, sub, nm, lo, hi = struct.unpack_from(">5H", blob.read(gpos_off + at, 10), 0)
            if d == 0:
                continue
            if sub == 0 and nm == 0 and lo == 0 and hi == 0:
                return (d, sub, nm, lo, hi)
            if lo <= d <= hi and 256 <= nm <= 32767:
                return (d, sub, nm, lo, hi)
    return None


def face(blob, off_in_file, fname, index):
    nt = u16(blob.read(off_in_file, 12), 4)
    d = blob.read(off_in_file + 12, 16 * nt)
    tables = {}
    for k in range(nt):
        tag, _, toff, tlen = struct.unpack_from(">4sIII", d, 16 * k)
        tables[tag] = (toff, tlen)
    want = {b"name": None, b"OS/2": 64, b"head": 54, b"post": 8, b"GPOS": 4096}
    blob.prefetch([(tables[t][0], min(tables[t][1], m) if m else tables[t][1]) for t, m in want.items() if t in tables])

    def table(tag, maxlen=None):
        if tag not in tables:
            return b""
        toff, tlen = tables[tag]
        return blob.read(toff, min(tlen, maxlen) if maxlen else tlen)

    names, ps = names_like_fontconfig_xetex(table(b"name"))
    os2 = table(b"OS/2", 64)
    hd = table(b"head", 54)
    post = table(b"post", 8)
    sz = size_params(blob, *tables[b"GPOS"]) if b"GPOS" in tables else None
    return {
        "file": fname, "index": index, "ps": ps, **names,
        "weight": u16(os2, 4) if len(os2) >= 8 else None,
        "width": u16(os2, 6) if len(os2) >= 8 else None,
        "fsSelection": u16(os2, 62) if len(os2) >= 64 else None,
        "macStyle": u16(hd, 44) if len(hd) >= 46 else None,
        "italicAngle": i32(post, 4) if len(post) >= 8 else None,
        "size": sz, "variable": b"fvar" in tables,
    }


def font(url, name, off, length):
    blob = Blob(url, off, length)
    blob.prefetch([(0, 12 + 16 * 48)])
    first = blob.read(0, 12)
    if first[:4] == b"ttcf":
        n = u32(first, 8)
        offs = blob.read(12, 4 * n)
        return [face(blob, u32(offs, 4 * k), name, k) for k in range(n)]
    return [face(blob, 0, name, 0)]


def c_str(s):
    out = []
    for ch in s.encode("utf-8"):
        out.append(chr(ch) if 32 <= ch < 127 and ch not in (34, 92, 63) else f"\\{ch:03o}")
    return '"' + "".join(out) + '"'


def write_c(path, digest, faces):
    sep = "\x1f"
    lines = [
        "/* taudot-fontindex.c: GENERATED by clients/render/texpresso/fonts/make_index.py; do not edit.",
        " * Names and style data of the fonts in one Tectonic bundle, for looking fonts up by name",
        " * (taudot-fonts.cpp). Font names are facts read from the fonts; this file is ours, MIT. */",
        "#include \"taudot-fonts.h\"",
        f"const char taudot_font_index_digest[] = {c_str(digest)};",
        f"const int taudot_font_index_count = {len(faces)};",
        "const struct taudot_indexed_font taudot_font_index[] = {",
    ]
    for f in faces:
        sz = f["size"] or (0, 0, 0, 0, 0)
        flags = (1 if f["weight"] is not None else 0) | (2 if f["macStyle"] is not None else 0) | \
                (4 if f["italicAngle"] is not None else 0) | (8 if f["size"] else 0) | (16 if f["variable"] else 0)
        lines.append("  {%s, %d, %s, %s, %s, %s, %d, %d, %d, %d, %d, %d, {%d, %d, %d, %d, %d}}," % (
            c_str(f["file"]), f["index"], c_str(f["ps"]), c_str(sep.join(f["family"])),
            c_str(sep.join(f["style"])), c_str(sep.join(f["full"])), flags,
            f["weight"] or 0, f["width"] or 0, f["fsSelection"] or 0, f["macStyle"] or 0, f["italicAngle"] or 0,
            *sz))
    lines.append("};")
    open(path, "w").write("\n".join(lines) + "\n")


def main(index_path, digest, out, *opts):
    url = DEFAULT_URL
    limit = None
    for k, o in enumerate(opts):
        if o == "--url":
            url = opts[k + 1]
        if o == "--limit":
            limit = int(opts[k + 1])
    url = resolve(url)
    entries = []
    for line in open(index_path):
        name, off, ln = line.rsplit(" ", 2)
        if name.lower().endswith((".otf", ".ttf", ".ttc", ".otc")):
            entries.append((name, int(off), int(ln)))
    entries.sort()
    if limit:
        entries = entries[:limit]
    print(f"{len(entries)} font files from {url}", file=sys.stderr)
    t0 = time.monotonic()
    faces, failed = [], []
    with cf.ThreadPoolExecutor(4) as ex:
        futs = {ex.submit(font, url, *e): e for e in entries}
        done = 0
        for fu in cf.as_completed(futs):
            e = futs[fu]
            try:
                faces.extend(fu.result())
            except TooMuch as x:
                print(f"STOP: {x} after {fetched} bytes, {requests} requests", file=sys.stderr)
                ex.shutdown(cancel_futures=True)
                sys.exit(3)
            except Exception as x:
                failed.append((e[0], repr(x)))
            done += 1
            if done % 200 == 0:
                print(f"  {done}/{len(entries)} fonts, {fetched / 1e6:.1f} MB, {requests} requests, "
                      f"{time.monotonic() - t0:.0f}s", file=sys.stderr)
    faces.sort(key=lambda f: (f["file"], f["index"]))
    write_c(out, digest, faces)
    print(f"{len(faces)} faces from {len(entries) - len(failed)} files; {len(failed)} failed; "
          f"{fetched / 1e6:.1f} MB in {requests} requests, {time.monotonic() - t0:.0f}s", file=sys.stderr)
    for n, x in failed:
        print(f"  failed: {n}: {x}", file=sys.stderr)


if __name__ == "__main__":
    main(*sys.argv[1:])
