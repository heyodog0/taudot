# Synthetic figures for the picture probe: PDFs with every page-box and /Rotate case, and PNG/JPEG/BMP files with
# and without resolution. Our own code (MIT).
#   uv run --with pillow==11.3.0 --with pikepdf==9.11.0 clients/render/texpresso/tests/pics/synthetic.py OUTDIR
import io
import sys
import zlib
from pathlib import Path

import pikepdf
from PIL import Image


def pdf(pages, inherit=None, version="1.4", catalog=""):
    """pages: list of dicts of page keys (MediaBox, CropBox, ..., Rotate) written as given. inherit: keys put
    on the /Pages node instead. Written by hand so every key is exactly as we say."""
    objs = []  # (num, bytes)

    def val(v):
        if isinstance(v, (list, tuple)):
            return "[" + " ".join(val(x) for x in v) + "]"
        return repr(v) if isinstance(v, float) else str(v)

    n = len(pages)
    kids = " ".join(f"{3 + 2 * i} 0 R" for i in range(n))
    pages_extra = "".join(f" /{k} {val(v)}" for k, v in (inherit or {}).items())
    objs.append(f"<< /Type /Catalog /Pages 2 0 R{catalog} >>".encode())
    objs.append(f"<< /Type /Pages /Kids [{kids}] /Count {n}{pages_extra} >>".encode())
    for i, p in enumerate(pages):
        p = dict(p)
        # dvipdfmx refuses a page with no /Resources (own or inherited), so give one unless told not to.
        if not p.pop("_nores", False) and "Resources" not in (inherit or {}):
            p.setdefault("Resources", "<< >>")
        keys = "".join(f" /{k} {val(v)}" for k, v in p.items())
        objs.append(f"<< /Type /Page /Parent 2 0 R /Contents {4 + 2 * i} 0 R{keys} >>".encode())
        content = b"0 0 1 rg 10 10 50 50 re f"
        objs.append(b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream")
    out = io.BytesIO()
    out.write(f"%PDF-{version}\n%\xe2\xe3\xcf\xd3\n".encode("latin-1"))
    offsets = []
    for i, body in enumerate(objs):
        offsets.append(out.tell())
        out.write(b"%d 0 obj\n" % (i + 1) + body + b"\nendobj\n")
    xref = out.tell()
    out.write(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1))
    for o in offsets:
        out.write(b"%010d 00000 n \n" % o)
    out.write(b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref))
    return out.getvalue()


M = [0, 0, 400, 300]
ALL = dict(MediaBox=M, CropBox=[10, 20, 390, 280], BleedBox=[5, 5, 395, 295], TrimBox=[30, 40, 370, 260],
           ArtBox=[50, 60, 350, 240])
PDFS = {
    "media-only": [dict(MediaBox=M)],
    "all-boxes": [ALL],
    "origin-offset": [dict(MediaBox=[100, 200, 500, 500], CropBox=[150, 250, 450, 450])],
    "negative-origin": [dict(MediaBox=[-50, -60, 350, 240])],
    "reversed-corners": [dict(MediaBox=[400, 300, 0, 0], CropBox=[390, 280, 10, 20])],
    "float-boxes": [dict(MediaBox=[0.5, 0.25, 400.75, 300.125], TrimBox=[10.333, 20.667, 300.1, 200.9])],
    "crop-outside-media": [dict(MediaBox=M, CropBox=[-20, -20, 500, 400])],
    "crop-partly-outside": [dict(MediaBox=M, CropBox=[200, 100, 600, 500])],
    "trim-no-crop": [dict(MediaBox=M, TrimBox=[30, 40, 370, 260])],
    "art-no-trim": [dict(MediaBox=M, CropBox=[10, 20, 390, 280], ArtBox=[50, 60, 350, 240])],
    "bleed-outside-crop": [dict(MediaBox=M, CropBox=[10, 20, 390, 280], BleedBox=[0, 0, 400, 300])],
    "rotate-90": [dict(ALL, Rotate=90)],
    "rotate-180": [dict(ALL, Rotate=180)],
    "rotate-270": [dict(ALL, Rotate=270)],
    "rotate-neg90": [dict(ALL, Rotate=-90)],
    "rotate-450": [dict(ALL, Rotate=450)],
    "rotate-45": [dict(ALL, Rotate=45)],
    "rotate-offset-90": [dict(MediaBox=[100, 200, 500, 500], CropBox=[150, 250, 450, 450], Rotate=90)],
    "no-mediabox": [dict()],
    "no-resources": [dict(MediaBox=M, _nores=True)],
    "rotate-real-90": [dict(ALL, Rotate=90.0)],
    "rotate-real-fraction": [dict(ALL, Rotate=90.5)],
    "rotate-not-number": [dict(ALL, Rotate="/Ninety")],
    "box-5-numbers": [dict(MediaBox=M, TrimBox=[30, 40, 370, 260, 1])],
    "box-not-number": [dict(MediaBox=M, TrimBox=[30, 40, "/x", 260])],
    "media-not-number": [dict(MediaBox=[0, 0, "/x", 300])],
    "box-not-array": [dict(MediaBox=M, ArtBox=7)],
    "multi-page": [dict(MediaBox=[0, 0, 100 + 50 * i, 200 + 10 * i], Rotate=90 * (i % 4)) for i in range(5)],
}
INHERIT = {
    "inherit-media": ([dict(), dict(CropBox=[10, 20, 390, 280])], dict(MediaBox=M)),
    "inherit-rotate": ([dict(MediaBox=M), dict(MediaBox=M, Rotate=0)], dict(Rotate=90)),
    "inherit-resources": ([dict(MediaBox=M, _nores=True)], dict(Resources="<< >>")),
    "inherit-crop": ([dict(MediaBox=M)], dict(MediaBox=[0, 0, 500, 500], CropBox=[10, 20, 390, 280])),
}


def main(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    for name, pages in PDFS.items():
        (out / f"{name}.pdf").write_bytes(pdf(pages))
    for name, (pages, inh) in INHERIT.items():
        (out / f"{name}.pdf").write_bytes(pdf(pages, inh))
    (out / "catalog-version-ok.pdf").write_bytes(pdf([ALL], catalog=" /Version /1.7"))
    (out / "catalog-version-string.pdf").write_bytes(pdf([ALL], catalog=" /Version (1.7)"))
    (out / "catalog-version-junk.pdf").write_bytes(pdf([ALL], catalog=" /Version /seven"))
    (out / "count-real.pdf").write_bytes(pdf([ALL, dict(MediaBox=[0, 0, 10, 20])]).replace(b"/Count 2", b"/Count 2.0"))
    (out / "count-too-big.pdf").write_bytes(pdf([ALL]).replace(b"/Count 1", b"/Count 3"))
    (out / "no-pdf-header.pdf").write_bytes(b"%XYZ" + pdf([ALL])[4:])
    with pikepdf.open(io.BytesIO(pdf([ALL]))) as p:
        p.save(out / "encrypted-empty-password.pdf", encryption=pikepdf.Encryption(owner="o", user=""))
    # A nested page tree: Pages(MediaBox) -> [Pages(Rotate 90, CropBox) -> [p1, p2], p3].
    nested = pikepdf.new()
    for i in range(3):
        nested.add_blank_page(page_size=(100 + 10 * i, 200))
    root = nested.Root.Pages
    k = list(root.Kids)
    inner = nested.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Pages, Kids=pikepdf.Array([k[0], k[1]]), Count=2,
                                                    Parent=root, Rotate=90, CropBox=pikepdf.Array([5, 5, 95, 150])))
    k[0].Parent = inner
    k[1].Parent = inner
    root.Kids = pikepdf.Array([inner, k[2]])
    root.MediaBox = pikepdf.Array([0, 0, 300, 400])
    for pg in (k[0], k[1]):
        del pg["/MediaBox"]
    nested.save(out / "nested-tree.pdf")
    # A compressed PDF 1.5 file with object and xref streams.
    with pikepdf.open(io.BytesIO(pdf([ALL, dict(MediaBox=[0, 0, 200, 100], Rotate=270)]))) as p:
        p.save(out / "objstreams.pdf", object_stream_mode=pikepdf.ObjectStreamMode.generate, compress_streams=True)
    # Incremental update that changes page 1's boxes.
    base = pdf([dict(MediaBox=M)])
    with pikepdf.open(io.BytesIO(base)) as p:
        p.pages[0].obj["/CropBox"] = pikepdf.Array([20, 30, 300, 200])
        buf = io.BytesIO()
        p.save(buf)
        (out / "rewritten.pdf").write_bytes(buf.getvalue())

    rgb = Image.new("RGB", (123, 45), (200, 30, 30))
    rgb.save(out / "png-nodpi.png")
    rgb.save(out / "png-300dpi.png", dpi=(300, 300))
    rgb.save(out / "png-72x150dpi.png", dpi=(72, 150))
    rgb.save(out / "png-odd-dpi.png", dpi=(96.5, 96.5))
    rgb.convert("P").save(out / "png-palette.png", dpi=(150, 150))
    rgb.convert("LA").save(out / "png-gray-alpha.png")
    Image.new("I;16", (77, 33), 1000).save(out / "png-16bit.png", dpi=(200, 200))
    rgb.save(out / "png-interlaced.png", interlace=1)
    # PNG with a pHYs chunk of unit 0 (aspect only): Pillow writes unit 1, so patch the byte.
    b = bytearray((out / "png-72x150dpi.png").read_bytes())
    i = b.find(b"pHYs")
    b[i + 12] = 0
    b[i + 13:i + 17] = zlib.crc32(bytes(b[i:i + 13])).to_bytes(4, "big")
    (out / "png-phys-unit0.png").write_bytes(bytes(b))

    rgb.save(out / "jpeg-nodpi.jpg")
    rgb.save(out / "jpeg-300dpi.jpg", dpi=(300, 300))
    rgb.save(out / "jpeg-72x150dpi.jpg", dpi=(72, 150))
    rgb.save(out / "jpeg-progressive.jpg", dpi=(150, 150), progressive=True)
    rgb.convert("CMYK").save(out / "jpeg-cmyk.jpg", dpi=(200, 200))
    rgb.convert("L").save(out / "jpeg-gray.jpg", dpi=(100, 100))
    exif = Image.Exif()
    exif[0x011A] = 240  # XResolution
    exif[0x011B] = 240  # YResolution
    exif[0x0128] = 2  # inches
    rgb.save(out / "jpeg-exif-240.jpg", exif=exif)
    rgb.save(out / "jpeg-jfif-and-exif.jpg", dpi=(300, 300), exif=exif)
    # JFIF density in dots per cm (units = 2): Pillow writes units 1, so patch the APP0 byte.
    b = bytearray((out / "jpeg-300dpi.jpg").read_bytes())
    i = b.find(b"JFIF\0")
    b[i + 7] = 2
    b[i + 8:i + 10] = (118).to_bytes(2, "big")
    b[i + 10:i + 12] = (118).to_bytes(2, "big")
    (out / "jpeg-dpcm.jpg").write_bytes(bytes(b))
    b[i + 7] = 0
    b[i + 8:i + 10] = (2).to_bytes(2, "big")
    b[i + 10:i + 12] = (1).to_bytes(2, "big")
    (out / "jpeg-aspect-only.jpg").write_bytes(bytes(b))

    # Exif before JFIF; Exif in cm; big-endian Exif; Exif with a rational the size of a fraction.
    def tiff(entries, big=False):
        e = ">" if big else "<"
        import struct
        n = len(entries)
        head = (b"MM" if big else b"II") + struct.pack(e + "HI", 42, 8)
        ifd = struct.pack(e + "H", n)
        data_off = 8 + 2 + 12 * n + 4
        extra = b""
        for tag, typ, val in entries:
            if typ == 5:
                ifd += struct.pack(e + "HHII", tag, 5, 1, data_off + len(extra))
                extra += struct.pack(e + "II", *val)
            else:
                ifd += struct.pack(e + "HHIH", tag, 3, 1, val) + b"\0\0"
        return head + ifd + b"\0\0\0\0" + extra
    def jpeg_with(segments):
        base = (out / "jpeg-nodpi.jpg").read_bytes()
        i = base.find(b"\xff\xe0")
        ln = int.from_bytes(base[i + 2:i + 4], "big")
        body = base[i + 2 + ln:]  # drop the JFIF segment
        seg = b"".join(m + (len(d) + 2).to_bytes(2, "big") + d for m, d in segments)
        return b"\xff\xd8" + seg + body
    jfif = lambda u, x, y: b"JFIF\0\x01\x01" + bytes([u]) + x.to_bytes(2, "big") + y.to_bytes(2, "big") + b"\0\0"
    exif = lambda t: b"Exif\0\0" + t
    E = lambda x, y, u=2, big=False: exif(tiff([(282, 5, (x, 1)), (283, 5, (y, 1)), (296, 3, u)], big))
    (out / "jpeg-exif-then-jfif.jpg").write_bytes(jpeg_with([(b"\xff\xe1", E(240, 240)), (b"\xff\xe0", jfif(1, 300, 300))]))
    (out / "jpeg-exif-only-cm.jpg").write_bytes(jpeg_with([(b"\xff\xe1", E(100, 50, 3))]))
    (out / "jpeg-exif-only-big.jpg").write_bytes(jpeg_with([(b"\xff\xe1", E(150, 200, 2, True))]))
    (out / "jpeg-exif-fraction.jpg").write_bytes(jpeg_with([(b"\xff\xe1", exif(tiff([(282, 5, (601, 2)), (283, 5, (601, 2))])))]))
    (out / "jpeg-exif-no-res.jpg").write_bytes(jpeg_with([(b"\xff\xe1", exif(tiff([(296, 3, 3)])))]))
    (out / "jpeg-jfif-zero-y.jpg").write_bytes(jpeg_with([(b"\xff\xe0", jfif(1, 300, 0))]))
    (out / "jpeg-no-app.jpg").write_bytes(jpeg_with([]))
    (out / "jpeg-truncated.jpg").write_bytes((out / "jpeg-300dpi.jpg").read_bytes()[:30])
    # PNG chunk order: pHYs after IDAT, two pHYs, pHYs with a bad CRC.
    def chunks(b):
        i, out_ = 8, []
        while i < len(b):
            n = int.from_bytes(b[i:i + 4], "big")
            out_.append(b[i:i + 12 + n])
            i += 12 + n
        return out_
    pc = chunks((out / "png-300dpi.png").read_bytes())
    phys = [c for c in pc if c[4:8] == b"pHYs"][0]
    other = [c for c in pc if c[4:8] != b"pHYs"]
    sig = b"\x89PNG\r\n\x1a\n"
    idat = [i for i, c in enumerate(other) if c[4:8] == b"IDAT"][0]
    (out / "png-phys-after-idat.png").write_bytes(sig + b"".join(other[:idat + 1] + [phys] + other[idat + 1:]))
    p2 = bytearray(phys); p2[8:16] = (5000).to_bytes(4, "big") * 2
    p2[16:20] = zlib.crc32(bytes(p2[4:16])).to_bytes(4, "big")
    (out / "png-two-phys.png").write_bytes(sig + b"".join(other[:1] + [phys, bytes(p2)] + other[1:]))
    bad = bytearray(phys); bad[-1] ^= 1
    (out / "png-phys-bad-crc.png").write_bytes(sig + b"".join(other[:1] + [bytes(bad)] + other[1:]))
    # BMP: core header, top-down (negative height), V5 header.
    import struct
    core = b"BM" + struct.pack("<IHHI", 26 + 3 * 4, 0, 0, 26) + struct.pack("<IHHHH", 12, 4, 3, 1, 24) + b"\0" * 12
    (out / "bmp-core.bmp").write_bytes(core)
    rgb.save(out / "bmp-nodpi.bmp")
    rgb.save(out / "bmp-300dpi.bmp", dpi=(300, 300))
    rgb.convert("P").save(out / "bmp-palette.bmp", dpi=(96, 96))
    top = bytearray((out / "bmp-300dpi.bmp").read_bytes())
    top[22:26] = struct.pack("<i", -45)
    (out / "bmp-top-down.bmp").write_bytes(bytes(top))
    v5 = bytearray(top[:14]) + struct.pack("<IiiHHIIiiII", 124, 123, 45, 1, 24, 0, 0, 2835, 5669, 0, 0) + b"\0" * (124 - 40)
    v5[10:14] = struct.pack("<I", 14 + 124)
    (out / "bmp-v5.bmp").write_bytes(bytes(v5) + b"\0" * (123 * 3 + 3) * 45)
    bad_res = bytearray(top); bad_res[6:10] = b"\1\0\0\0"
    (out / "bmp-bad-reserved.bmp").write_bytes(bytes(bad_res))
    (out / "not-an-image.png").write_bytes(b"hello\n")
    (out / "empty.pdf").write_bytes(b"")
    print(f"wrote {len(list(out.iterdir()))} files to {out}")


if __name__ == "__main__":
    main(sys.argv[1])
