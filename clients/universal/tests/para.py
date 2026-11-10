# MIT. Lines of a typeset page, from a PDF content stream (pdfTeX, LuaTeX) or an XDV page (XeTeX), for checking the
# paragraph pass against the exact page: a line is its baseline y and its text-showing operations (font, size, x,
# the operation's operand bytes), in order.
import re
import struct
import zlib

STREAM = re.compile(rb"<<(.*?)>>\s*stream\r?\n", re.S)


PLAIN = re.compile(rb"\s*(/(Length|Filter|DecodeParms)\s*(\d+(\s+\d+\s+R)?|/\w+|\[[^\]]*\]|<<[^>]*>>)\s*)*")


def streams(b, content=False):
    """Decoded streams of a PDF fragment, in order. CONTENT: only content streams (a dictionary of /Length, /Filter,
    /DecodeParms alone: not a figure's form XObject, image or font program written at the same ship)."""
    out = []
    for m in STREAM.finditer(b):
        d = m.group(1)
        if content and not PLAIN.fullmatch(d):
            continue
        ln = re.search(rb"/Length (\d+)(?! \d+ R)", d)
        start = m.end()
        if ln:
            data = b[start:start + int(ln.group(1))]
        else:
            data = b[start:b.find(b"endstream", start)]
        if b"/FlateDecode" in d:
            try:
                data = zlib.decompress(data)
            except zlib.error:
                continue
        out.append(data)
    return out


TOK = re.compile(rb"\((?:\\.|[^\\)])*\)|<[0-9A-Fa-f\s]*>|\[|\]|/[^\s/\[\]()<>]+|[-+]?\d*\.?\d+|[A-Za-z'\"*]+")


def pdf_runs(content, spans=False):
    """(y, x, font, size, operand) for every text show, positions from the text line matrix and the CTM's offset.
    SPANS: each also with the byte span (start, end) of its operand in CONTENT."""
    runs, stack, arr, depth = [], [], [], 0
    lx = ly = 0.0
    font, size = b"", 0.0
    cm = [(0.0, 0.0)]
    starts, arr_start = [], 0
    for m in TOK.finditer(content):
        t = m.group(0)
        if t == b"[":
            if depth == 0:
                arr_start = m.start()
            depth += 1
            arr.append(t)
            continue
        if t == b"]":
            depth -= 1
            arr.append(t)
            if depth == 0:
                stack.append(b"".join(arr))
                starts.append((arr_start, m.end()))
                arr = []
            continue
        if depth:
            arr.append(t)
            continue
        if t[:1].isalpha() or t in (b"'", b'"', b"T*"):
            op = t
            if op == b"BT":
                lx = ly = 0.0
            elif op == b"Tf" and len(stack) >= 2:
                font, size = stack[-2], float(stack[-1])
            elif op in (b"Td", b"TD") and len(stack) >= 2:
                lx += float(stack[-2])
                ly += float(stack[-1])
            elif op == b"Tm" and len(stack) >= 6:
                lx, ly = float(stack[-2]), float(stack[-1])
            elif op == b"cm" and len(stack) >= 6:
                ox, oy = cm[-1]
                cm[-1] = (ox + float(stack[-2]), oy + float(stack[-1]))
            elif op == b"q":
                cm.append(cm[-1])
            elif op == b"Q" and len(cm) > 1:
                cm.pop()
            elif op in (b"TJ", b"Tj") and stack:
                ox, oy = cm[-1]
                r = (round(ly + oy, 4), round(lx + ox, 4), font, size, stack[-1])
                runs.append(r + (starts[-1],) if spans else r)
            stack, starts = [], []
        else:
            stack.append(t)
            starts.append((m.start(), m.end()))
    return runs


def xdv_runs(page):
    """(y, x, font, 0, glyphs) for every glyph run of one XDV page (bop..eop), in DVI units."""
    runs, st = [], []
    h = v = w = x = y = z = 0
    f = 0
    i = 45
    b = page
    n = len(b)
    while i < n:
        op = b[i]
        i += 1
        if op < 128:
            runs.append((v, h, f, 0, bytes([op])))  # set_char (rare in XDV)
        elif 171 <= op <= 234:
            f = op - 171
        elif 235 <= op <= 238:
            k = op - 234
            f = int.from_bytes(b[i:i + k], "big")
            i += k
        elif op in (141,):
            st.append((h, v, w, x, y, z))
        elif op == 142:
            h, v, w, x, y, z = st.pop()
        elif 143 <= op <= 146:
            k = op - 142
            h += int.from_bytes(b[i:i + k], "big", signed=True)
            i += k
        elif op == 147:
            h += w
        elif 148 <= op <= 151:
            k = op - 147
            w = int.from_bytes(b[i:i + k], "big", signed=True)
            h += w
            i += k
        elif op == 152:
            h += x
        elif 153 <= op <= 156:
            k = op - 152
            x = int.from_bytes(b[i:i + k], "big", signed=True)
            h += x
            i += k
        elif 157 <= op <= 160:
            k = op - 156
            v += int.from_bytes(b[i:i + k], "big", signed=True)
            i += k
        elif op == 161:
            v += y
        elif 162 <= op <= 165:
            k = op - 161
            y = int.from_bytes(b[i:i + k], "big", signed=True)
            v += y
            i += k
        elif op == 166:
            v += z
        elif 167 <= op <= 170:
            k = op - 166
            z = int.from_bytes(b[i:i + k], "big", signed=True)
            v += z
            i += k
        elif op in (132, 137):
            i += 8
        elif 128 <= op <= 131 or 133 <= op <= 136:
            i += (op - 127) if op <= 131 else (op - 132)
        elif 239 <= op <= 242:
            k = op - 238
            ln = int.from_bytes(b[i:i + k], "big")
            i += k + ln
        elif 243 <= op <= 246:
            k = op - 242
            i += k + 12
            i += 2 + b[i] + b[i + 1]
        elif op == 252:
            i += 8
            flags = struct.unpack(">H", b[i:i + 2])[0]
            i += 2
            i += 1 + b[i] + 4
            for bit in (0x0200, 0x1000, 0x2000, 0x4000):
                if flags & bit:
                    i += 4
        elif op == 253:
            wd = struct.unpack(">i", b[i:i + 4])[0]
            k = struct.unpack(">H", b[i + 4:i + 6])[0]
            body = b[i + 6:i + 6 + 10 * k]
            runs.append((v, h, f, 0, body))
            h += wd
            i += 6 + 10 * k
        elif op == 254:
            ln = struct.unpack(">H", b[i:i + 2])[0]
            i += 2 + 2 * ln
            wd = struct.unpack(">i", b[i:i + 4])[0]
            k = struct.unpack(">H", b[i + 4:i + 6])[0]
            body = b[i + 6:i + 6 + 10 * k]
            runs.append((v, h, f, 0, body))
            h += wd
            i += 6 + 10 * k
        elif op in (138, 140):
            if op == 140:
                break
        elif op == 139:
            i += 44
    return runs


LINENO = re.compile(rb"^\[\(\d{1,3}\)\]$")


def text_runs(runs):
    """Without review-mode margin line numbers (lineno: one block per page, not part of any paragraph)."""
    return [r for r in runs if not LINENO.match(r[4])]


def lines(runs, pdf=True):
    """Runs grouped into lines, top to bottom: [(y, [(dy, x, font, size, operand), ...]), ...]. A line is a cluster of
    baselines less than 5 pt apart (sub- and superscripts), y its first baseline."""
    gap = 5.0 if pdf else 5 * 65536
    rs = sorted(runs, key=lambda r: -r[0] if pdf else r[0])
    out = []
    for y, x, f, s, o in rs:
        if not out or abs(y - out[-1][2]) > gap:
            out.append([y, [], y])
        out[-1][2] = y
        out[-1][1].append((round(y - out[-1][0], 4), x, f, s, o))  # (4: y + dy gives the run's own baseline back)
    return [(y, sorted(r, key=lambda t: (t[0], t[1]))) for y, r, _ in out]


def match(ours, page, n):
    """Do OUR last N lines appear, identical, as N consecutive lines of PAGE? Positions relative to the first
    line's first run: the pass ships at natural height without LaTeX's margins (a constant offset)."""
    if n <= 0 or len(ours) < n:
        return False

    def norm(ls):
        if not ls or not ls[0][1]:
            return None
        y0, x0 = ls[0][0], ls[0][1][0][1]
        return [(round(y - y0, 2), [(dy, round(x - x0, 2), f, s, o) for dy, x, f, s, o in r]) for y, r in ls]

    def same(a, b):  # positions within 0.05 pt: pdfTeX prints 3 decimals and we sum relative moves
        if a is None or b is None or len(a) != len(b):
            return False
        for (ya, ra), (yb, rb) in zip(a, b):
            if abs(ya - yb) > 0.05 or len(ra) != len(rb):
                return False
            for (dya, xa, fa, sa, oa), (dyb, xb, fb, sb, ob) in zip(ra, rb):
                if (fa, sa, oa) != (fb, sb, ob) or abs(dya - dyb) > 0.05 or abs(xa - xb) > 0.05:
                    return False
        return True

    mine = norm(ours[-n:])
    return any(same(norm(page[i:i + n]), mine) for i in range(len(page) - n + 1))


TJTOK = re.compile(rb"\((?:\\.|[^\\)])*\)|<[0-9A-Fa-f]*>|[-+]?\d*\.?\d+")


def split_op(o):
    """A TJ/Tj operand as (its strings, its numbers). pdfTeX rounds kerns against the page origin, so a line shipped
    at another x can differ by 1 in a number (0.01 pt) with the same glyphs."""
    if not isinstance(o, bytes):
        return o, ()
    toks = TJTOK.findall(o)
    return b"".join(t[1:-1] for t in toks if t[:1] in b"(<"), tuple(float(t) for t in toks if t[:1] not in b"(<")


def same_nums(a, b):
    """Kerns equal within 1 unit; ±1 correction kerns (pdfTeX inserts them inside words when its rounding against
    the origin drifts, e.g. (z)1(ero)) are ignored."""
    a = [x for x in a if abs(x) > 1.0]
    b = [x for x in b if abs(x) > 1.0]
    return len(a) == len(b) and all(abs(x - y) <= 1.0 for x, y in zip(a, b))


def match_anchored(ours, page_runs, n, tol=0.05):
    """OUR last N lines' runs all appear in PAGE_RUNS at the same offsets from one anchor run (columns, line
    clustering and the pass's missing margins don't matter); kern numbers within 1 unit."""
    if n <= 0 or len(ours) < n:
        return False
    mine = [(y + dy, x, f, s, split_op(o)) for y, r in ours[-n:] for dy, x, f, s, o in r]
    if not mine:
        return False
    idx = {}
    for y, x, f, s, o in page_runs:
        st, nums = split_op(o)
        idx.setdefault((f, s, st), []).append((y, x, nums))
    ay, ax, af, as_, (ast, anums) = mine[0]
    for py, px, pn in idx.get((af, as_, ast), []):
        if not same_nums(pn, anums):
            continue
        dy, dx = py - ay, px - ax
        if all(any(abs(qy - (y + dy)) <= tol and abs(qx - (x + dx)) <= tol and same_nums(qn, nums)
                   for qy, qx, qn in idx.get((f, s, st), []))
               for y, x, f, s, (st, nums) in mine[1:]):
            return True
    return False


def xdv_walk(b, i):
    """Index just past the eop of the page whose bop is at I, or -1."""
    try:
        runs = xdv_runs(b[i:])
    except (IndexError, ValueError, struct.error):
        return -1
    return runs


def xdv_pass_page(b):
    """The pass's page in an XDV fragment: the last complete page (bop .. eop) that draws glyphs. The padding page
    after it may or may not have reached the file (the DVI buffer is written in halves)."""
    j = len(b)
    while True:
        j = b.rfind(b"\x8b", 0, j)
        if j < 0:
            return None
        try:
            runs = xdv_runs(b[j:])
        except (IndexError, ValueError, struct.error):
            continue
        if runs and b.find(b"\x8c", j) >= 0:
            return b[j:]


def glyphs(o):
    """What a run draws, without positions: a PDF operand's strings, or an XDV glyph run's glyph ids."""
    if isinstance(o, bytes) and o[:1] in (b"[", b"(", b"<"):
        return split_op(o)[0]
    k = len(o) // 10
    return o[8 * k:]


def match_lines(ours, page_runs, n, tol=0.05, pdf=True, strict=False):
    """OUR last N lines are N lines of the page: each line draws the same glyphs (concatenated), starts at the same
    x and lies at the same offset from the first, relative to an anchor (the first line's first run). Positions
    inside a line aren't compared run by run: pdfTeX splits TJ runs and adds 1-unit kerns by its rounding against the
    page origin, which differs at another x. STRICT (XDV: integer sp, no rounding): whole runs, positions inside
    them included, must be byte-equal. Returns the offset (dx, dy) from the pass to the page, or None."""
    if n <= 0 or len(ours) < n:
        return False
    mine = ours[-n:]
    if not mine[0][1]:
        return False
    a = mine[0][1][0]
    ay, ax = mine[0][0] + a[0], a[1]
    xs = [x for y, r in mine for dy, x, f, s, o in r]
    g = (lambda o: o) if strict else glyphs
    sig = [(round(y - mine[0][0], 2), min(x for dy, x, f, s, o in r), b"".join(g(o) for dy, x, f, s, o in r))
           for y, r in mine]
    for py, px, pf, ps, po in page_runs:
        if (pf, ps) != (a[2], a[3]) or glyphs(po) != glyphs(a[4]):
            continue
        dy, dx = py - ay, px - ax
        lo, hi = min(xs) + dx - 0.5 * (1 if pdf else 65536), max(xs) + dx + 0.5 * (1 if pdf else 65536)
        region = [r for r in page_runs if lo <= r[1] <= hi]
        L = lines(region, pdf)
        ys = [y for y, r in L]
        start = [i for i, y in enumerate(ys) if abs(y - (mine[0][0] + dy)) <= tol]
        if not start:
            continue
        cand = L[start[0]:start[0] + n]
        if len(cand) != n:
            continue
        got = [(round(y - cand[0][0], 2), min(x for dy_, x, f, s, o in r) - dx, b"".join(g(o) for dy_, x, f, s, o in r))
               for y, r in cand]
        if all(abs(a_[0] - m[0]) <= tol and abs(a_[1] - m[1]) <= tol and a_[2] == m[2] for a_, m in zip(got, sig)):
            return (dx, dy)
    return None
