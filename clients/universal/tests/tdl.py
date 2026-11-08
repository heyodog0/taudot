# MIT. Read a TDL list (clients/render/dlist.md): its TEXT runs' glyphs (text, origin), for checks.
import struct
import sys


def runs(path):
    b = open(path, "rb").read()
    assert b[:4] == b"TDL\0", "not a TDL list"
    i, out, page = 8, [], None
    while i < len(b):
        kind, ln = b[i], struct.unpack_from("<I", b, i + 1)[0]
        p = b[i + 5:i + 5 + ln]
        i += 5 + ln
        if kind == 0x00:
            break
        if kind == 0x01:
            page = struct.unpack_from("<Iff", p)
        if kind == 0x10:
            k = 16
            mode = p[k]; k += 1 + 16
            if mode == 1:
                k += 4 + 1 + 1 + 4 + 4
                nd = struct.unpack_from("<H", p, k)[0]; k += 2 + 4 * nd
            font = struct.unpack_from("<I", p, k)[0]; k += 4 + 16
            n = struct.unpack_from("<I", p, k)[0]; k += 4
            gl = []
            for _ in range(n):
                gid, x, y, adv = struct.unpack_from("<Ifff", p, k); k += 16
                tl = struct.unpack_from("<H", p, k)[0]; k += 2
                gl.append((x, y, p[k:k + tl].decode("utf8", "replace"))); k += tl
            out.append((font, gl))
    return page, out


if __name__ == "__main__":
    page, rs = runs(sys.argv[1])
    print("page", page, "runs", len(rs))
    lines = {}
    for font, gl in rs:
        for x, y, t in gl:
            lines.setdefault(round(y, 1), []).append((x, t))
    for y in sorted(lines):
        print(f"  y {y:7.1f}: " + "".join(t for x, t in sorted(lines[y]))[:100])
