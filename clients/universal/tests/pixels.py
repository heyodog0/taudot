# MIT. An independent check of the paragraph pass: draw the pass's lines and the exact page's same lines with Core
# Graphics (no MuPDF) and count the pixels that differ. No tolerance: any channel of any pixel counts.
#
# The pass's content stream becomes a page of a copy of the exact PDF (all the document's fonts in its resources),
# moved by the offset the line match found, so both are drawn by the same renderer from the same fonts.
import io

import pikepdf
import Quartz
from Foundation import NSData

SCALE = 4  # 288 dpi


def pass_pdf(exact_path, page_index, content, dx, dy):
    pdf = pikepdf.open(exact_path)
    page = pdf.pages[page_index]
    fonts, xobjs = pikepdf.Dictionary(), pikepdf.Dictionary()
    for pg in pdf.pages:  # the pass may use a font the page doesn't (first used elsewhere)
        res = pg.obj.get("/Resources", {})
        for k, v in res.get("/Font", {}).items():
            fonts[k] = v
        for k, v in res.get("/XObject", {}).items():
            xobjs[k] = v
    res = page.obj.get("/Resources") or pikepdf.Dictionary()
    res["/Font"] = fonts
    res["/XObject"] = xobjs
    page.obj["/Resources"] = res
    page.obj["/Contents"] = pdf.make_stream(b"q 1 0 0 1 %.4f %.4f cm\n" % (dx, dy) + content + b"\nQ\n")
    if "/Annots" in page.obj:
        del page.obj["/Annots"]
    out = io.BytesIO()
    pdf.save(out)
    return out.getvalue()


def other_pdf(exact_path, page_index, content):
    """The exact PDF with page PAGE_INDEX drawing CONTENT: the page without the paragraph's lines (their text shows
    emptied), so what remains in a rect is the page's other ink (a table or figure reaching into the column)."""
    pdf = pikepdf.open(exact_path)
    page = pdf.pages[page_index]
    page.obj["/Contents"] = pdf.make_stream(content)
    if "/Annots" in page.obj:
        del page.obj["/Annots"]
    out = io.BytesIO()
    pdf.save(out)
    return out.getvalue()


def inked(rgba, i):
    return rgba[i:i + 3] != b"\xff\xff\xff"


def render(pdf_bytes, page_index, rect):
    """RGBA bytes of RECT (x0, y0, x1, y1 in PDF points) of a page, at SCALE, on white."""
    data = NSData.dataWithBytes_length_(pdf_bytes, len(pdf_bytes))
    doc = Quartz.CGPDFDocumentCreateWithProvider(Quartz.CGDataProviderCreateWithCFData(data))
    page = Quartz.CGPDFDocumentGetPage(doc, page_index + 1)
    x0, y0, x1, y1 = rect
    w, h = int(round((x1 - x0) * SCALE)), int(round((y1 - y0) * SCALE))
    cs = Quartz.CGColorSpaceCreateDeviceRGB()
    ctx = Quartz.CGBitmapContextCreate(None, w, h, 8, w * 4, cs, Quartz.kCGImageAlphaPremultipliedLast)
    Quartz.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1)
    Quartz.CGContextFillRect(ctx, Quartz.CGRectMake(0, 0, w, h))
    Quartz.CGContextScaleCTM(ctx, SCALE, SCALE)
    Quartz.CGContextTranslateCTM(ctx, -x0, -y0)
    Quartz.CGContextDrawPDFPage(ctx, page)
    img = Quartz.CGBitmapContextCreateImage(ctx)
    return bytes(Quartz.CGDataProviderCopyData(Quartz.CGImageGetDataProvider(img))), w, h


def ink_right(rgba, w, h, left_px):
    right = left_px
    for y in range(h):
        row = rgba[y * w * 4:(y + 1) * w * 4]
        for x in range(w - 1, right, -1):
            if row[4 * x] < 250 or row[4 * x + 1] < 250 or row[4 * x + 2] < 250:
                right = x
                break
    return right


def diff(exact_path, page_index, content, dx, dy, baselines, x_start, other=None):
    """(differing pixels, visibly differing pixels (> 64 in a channel), pixels compared). BASELINES and X_START
    are in the pass's coordinates; the band runs from 3 pt below the last baseline to 7.5 pt above the first."""
    with open(exact_path, "rb") as f:
        exact = f.read()
    mine = pass_pdf(exact_path, page_index, content, dx, dy)
    top, bottom = max(baselines) + dy + 7.5, min(baselines) + dy - 3
    left = x_start + dx - 1
    with pikepdf.open(exact_path) as doc:
        pw = float(doc.pages[page_index].mediabox[2])
    a, w, h = render(mine, page_index, (left, bottom, pw, top))
    right = left + (ink_right(a, w, h, 0) + 1) / SCALE + 2
    a, w, h = render(mine, page_index, (left, bottom, right, top))
    b, _, _ = render(exact, page_index, (left, bottom, right, top))
    # OTHER (the page's content without the paragraph's lines): where it has ink, a differing pixel is the page's other
    # ink (alone, or over the paragraph's glyphs), not the paragraph
    o = render(other, page_index, (left, bottom, right, top))[0] if other else None
    n = vis = foreign = 0
    import os
    dump = os.environ.get("PIX_DUMP")
    if dump and a != b:
        from PIL import Image, ImageChops
        os.makedirs(dump, exist_ok=True)
        k = len(os.listdir(dump)) // 3
        ia, ib = Image.frombytes("RGBA", (w, h), a), Image.frombytes("RGBA", (w, h), b)
        ia.save(f"{dump}/{k}-pass.png"); ib.save(f"{dump}/{k}-exact.png")
        ImageChops.difference(ia.convert("RGB"), ib.convert("RGB")).point(lambda v: 255 if v else 0).save(f"{dump}/{k}-diff.png")
    for i in range(0, len(a), 4):
        d = max(abs(a[i] - b[i]), abs(a[i + 1] - b[i + 1]), abs(a[i + 2] - b[i + 2]))
        if d:
            if a[i] == a[i + 1] == a[i + 2] == 255 or (o and inked(o, i)):  # the pass draws nothing here, or the
                foreign += 1  # page has other ink here (a figure, a table from the next column): not the paragraph
                continue
            n += 1
            vis += d > 64
    return n, vis, w * h, foreign


def page_height(pdf_bytes, page_index):
    data = NSData.dataWithBytes_length_(pdf_bytes, len(pdf_bytes))
    doc = Quartz.CGPDFDocumentCreateWithProvider(Quartz.CGDataProviderCreateWithCFData(data))
    r = Quartz.CGPDFPageGetBoxRect(Quartz.CGPDFDocumentGetPage(doc, page_index + 1), Quartz.kCGPDFMediaBox)
    return r.origin.y + r.size.height


def event_check(ev, exact_path, other=None):
    """A para event as the app draws it: the overlay's page (at origin) against the exact page, over the new
    lines' erase rect. Differing pixels (no tolerance)."""
    ov = open(ev["overlay"], "rb").read()
    ex = open(exact_path, "rb").read()
    H = page_height(ex, ev["page"])
    x0, y0, x1, y1 = ev["erase"][1]
    ox, oy = ev.get("origin", [0, 0])
    a, w, h = render(ov, 0, (x0 - ox, H - y1 + oy, x1 - ox, H - y0 + oy))
    b, _, _ = render(ex, ev["page"], (x0, H - y1, x1, H - y0))
    # (pixels where the overlay draws nothing and the page has ink: other content in the rect, counted apart)
    o = render(other, ev["page"], (x0, H - y1, x1, H - y0))[0] if other else None
    import os
    dump = os.environ.get("PIX_DUMP")
    if dump:
        from PIL import Image
        os.makedirs(dump, exist_ok=True)
        k = len(os.listdir(dump))
        Image.frombytes("RGBA", (w, h), a).save(f"{dump}/ev{k}-overlay.png")
        Image.frombytes("RGBA", (w, h), b).save(f"{dump}/ev{k}-exact.png")
    diff = [i for i in range(0, len(a), 4) if a[i:i + 3] != b[i:i + 3]]
    foreign = sum(1 for i in diff if a[i:i + 3] == b"\xff\xff\xff" or (o and inked(o, i)))
    return len(diff) - foreign, w * h, foreign
