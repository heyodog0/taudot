# MIT. Split an XDV (or DVI) file into its pages' bytes (bop .. eop), for comparisons.
import struct

FIXED = {132: 8, 137: 8, 138: 0, 140: 0, 141: 0, 142: 0, 147: 0, 152: 0, 161: 0, 166: 0}
for base in (128, 133, 143, 148, 153, 157, 162, 167, 235):  # set, put, right, w, x, down, y, z, fnt: 1-4 bytes
    for i in range(4):
        FIXED[base + i] = i + 1


def pages(b):
    out, i, start = [], 0, None
    n = len(b)
    while i < n:
        op = b[i]
        i += 1
        if op < 128 or 171 <= op <= 234:
            continue
        if op in FIXED:
            if op == 140 and start is not None:
                out.append(b[start:i])
                start = None
            i += FIXED[op]
        elif op == 139:  # bop: c0..c9, p
            start = i - 1
            i += 44
        elif 239 <= op <= 242:  # xxx
            k = op - 238
            ln = int.from_bytes(b[i:i + k], "big")
            i += k + ln
        elif 243 <= op <= 246:  # fnt_def
            k = op - 242
            i += k + 12
            a, l = b[i], b[i + 1]
            i += 2 + a + l
        elif op == 247:  # pre
            i += 13
            i += 1 + b[i]
        elif op == 248:  # post: the pages are over
            break
        elif op == 252:  # define_native_font
            i += 4 + 4
            flags = struct.unpack(">H", b[i:i + 2])[0]
            i += 2
            ln = b[i]
            i += 1 + ln + 4
            for bit in (0x0200, 0x1000, 0x2000, 0x4000):
                if flags & bit:
                    i += 4
        elif op == 253:  # set_glyphs
            i += 4
            k = struct.unpack(">H", b[i:i + 2])[0]
            i += 2 + 10 * k
        elif op == 254:  # set_text_and_glyphs
            ln = struct.unpack(">H", b[i:i + 2])[0]
            i += 2 + 2 * ln + 4
            k = struct.unpack(">H", b[i:i + 2])[0]
            i += 2 + 10 * k
        else:
            raise ValueError(f"xdv: opcode {op} at {i - 1}")
    return out
