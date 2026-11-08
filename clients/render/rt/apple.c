/* Taudot's drawing runtime: what Apple's frameworks do for it. Images (ImageIO), included PDF pages (Core Graphics'
 * PDF parser, for boxes only: the page is drawn by TaudotRender) and CMYK colours (ColorSync's generic CMYK).
 * Copyright (c) 2026 the Taudot authors. MIT License (rt/LICENSE). */

#include "mupdf/fitz.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

/* ---- images ------------------------------------------------------------------------------------------------------- */

static CGImageSourceRef source_for(fz_buffer *b)
{
  CFDataRef d = CFDataCreateWithBytesNoCopy(NULL, b->data, (CFIndex)b->len, kCFAllocatorNull);
  CGImageSourceRef s = CGImageSourceCreateWithData(d, NULL);
  CFRelease(d);
  return s;
}

static double dict_num(CFDictionaryRef d, CFStringRef key, double dflt)
{
  CFNumberRef n = d ? CFDictionaryGetValue(d, key) : NULL;
  double v = dflt;
  if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberDoubleType, &v);
  return v;
}

fz_image *fz_new_image_from_buffer(fz_context *ctx, fz_buffer *buffer)
{
  CGImageSourceRef src = source_for(buffer);
  if (!src || CGImageSourceGetCount(src) < 1)
  {
    if (src) CFRelease(src);
    fz_throw(ctx, FZ_ERROR_FORMAT, "unknown image format");
  }
  CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
  int w = (int)dict_num(props, kCGImagePropertyPixelWidth, 0), h = (int)dict_num(props, kCGImagePropertyPixelHeight, 0);
  double dpi_x = dict_num(props, kCGImagePropertyDPIWidth, 72), dpi_y = dict_num(props, kCGImagePropertyDPIHeight, 72);
  int alpha = 0, n = 3;
  CFStringRef model = props ? CFDictionaryGetValue(props, kCGImagePropertyColorModel) : NULL;
  if (model && CFEqual(model, kCGImagePropertyColorModelGray)) n = 1;
  else if (model && CFEqual(model, kCGImagePropertyColorModelCMYK)) n = 4;
  CFBooleanRef ha = props ? CFDictionaryGetValue(props, kCGImagePropertyHasAlpha) : NULL;
  if (ha && CFBooleanGetValue(ha)) alpha = 1;
  if (props) CFRelease(props);
  CFRelease(src);
  if (w <= 0 || h <= 0) fz_throw(ctx, FZ_ERROR_FORMAT, "image without size");

  fz_image *img = fz_malloc_struct(ctx, fz_image);
  img->refs = 1;
  img->w = w;
  img->h = h;
  img->n = n;
  img->alpha = alpha;
  img->xres = dpi_x > 0 ? (int)(dpi_x + 0.5) : 72;
  img->yres = dpi_y > 0 ? (int)(dpi_y + 0.5) : 72;
  img->colorspace = n == 1 ? fz_device_gray(ctx) : n == 4 ? fz_device_cmyk(ctx) : fz_device_rgb(ctx);
  img->buffer = fz_keep_buffer(ctx, buffer);
  const unsigned char *d = buffer->data;
  if (buffer->len > 8 && !memcmp(d, "\x89PNG\r\n\x1a\n", 8)) img->type = FZ_IMAGE_PNG;
  else if (buffer->len > 3 && d[0] == 0xff && d[1] == 0xd8 && d[2] == 0xff) img->type = FZ_IMAGE_JPEG;
  else img->type = FZ_IMAGE_OTHER;
  return img;
}

fz_image *fz_new_image_from_file(fz_context *ctx, const char *path)
{
  fz_buffer *b = fz_read_file(ctx, path);
  fz_image *img = NULL;
  fz_try(ctx) img = fz_new_image_from_buffer(ctx, b);
  fz_always(ctx) fz_drop_buffer(ctx, b);
  fz_catch(ctx) fz_rethrow(ctx);
  return img;
}

fz_image *fz_keep_image(fz_context *ctx, fz_image *img) { (void)ctx; if (img) img->refs++; return img; }

void fz_drop_image(fz_context *ctx, fz_image *img)
{
  if (!img || --img->refs > 0) return;
  fz_drop_buffer(ctx, img->buffer);
  free(img);
}

void fz_image_resolution(fz_image *img, int *xres, int *yres)
{
  *xres = img->xres;
  *yres = img->yres;
}

unsigned char *fz_image_rgba(fz_context *ctx, fz_image *img, int *pw, int *ph)
{
  (void)ctx;
  CGImageSourceRef src = source_for(img->buffer);
  CGImageRef im = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
  if (src) CFRelease(src);
  if (!im) return NULL;
  int w = (int)CGImageGetWidth(im), h = (int)CGImageGetHeight(im);
  unsigned char *px = calloc((size_t)w * h, 4);
  CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef cx = CGBitmapContextCreate(px, w, h, 8, (size_t)w * 4, rgb,
                                          kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(rgb);
  if (!cx) { CGImageRelease(im); free(px); return NULL; }
  CGContextSetBlendMode(cx, kCGBlendModeCopy);
  CGContextDrawImage(cx, CGRectMake(0, 0, w, h), im);
  CGContextRelease(cx);
  CGImageRelease(im);
  /* not premultiplied, as TDL wants */
  for (size_t i = 0; i < (size_t)w * h; i++)
  {
    unsigned char *p = px + i * 4;
    int a = p[3];
    if (a > 0 && a < 255)
      for (int k = 0; k < 3; k++) { int v = (p[k] * 255 + a / 2) / a; p[k] = v > 255 ? 255 : v; }
  }
  *pw = w;
  *ph = h;
  return px;
}

/* ---- included PDF pages ------------------------------------------------------------------------------------------- */

/* documents stay open for the process: figures are few and reused on every typeset */
typedef struct { char *path; CGPDFDocumentRef doc; } doc_cell;
static doc_cell docs[64];
static int ndocs;

static CGPDFDocumentRef open_doc(const char *path)
{
  for (int i = 0; i < ndocs; i++)
    if (!strcmp(docs[i].path, path)) return docs[i].doc;
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
  CGPDFDocumentRef doc = url ? CGPDFDocumentCreateWithURL(url) : NULL;
  if (url) CFRelease(url);
  if (!doc) return NULL;
  if (ndocs == 64)
  {
    CGPDFDocumentRelease(docs[0].doc);
    free(docs[0].path);
    memmove(docs, docs + 1, sizeof(doc_cell) * 63);
    ndocs--;
  }
  docs[ndocs].path = strdup(path);
  docs[ndocs].doc = doc;
  ndocs++;
  return doc;
}

/* A file changed on disk is opened again (the editor saves figures while the preview runs). */
void rt_forget_figure_file(const char *path)
{
  for (int i = 0; i < ndocs; i++)
    if (!strcmp(docs[i].path, path))
    {
      CGPDFDocumentRelease(docs[i].doc);
      free(docs[i].path);
      memmove(docs + i, docs + i + 1, sizeof(doc_cell) * (ndocs - i - 1));
      ndocs--;
      return;
    }
}

int fz_figure_page_count(fz_context *ctx, const char *path)
{
  (void)ctx;
  CGPDFDocumentRef d = open_doc(path);
  return d ? (int)CGPDFDocumentGetNumberOfPages(d) : 0;
}

fz_figure *fz_new_figure(fz_context *ctx, const char *path, int page)
{
  CGPDFDocumentRef d = open_doc(path);
  if (!d) return NULL;
  int n = (int)CGPDFDocumentGetNumberOfPages(d);
  if (page < 1) page = 1;
  if (page > n) return NULL;
  CGPDFPageRef p = CGPDFDocumentGetPage(d, page);
  if (!p) return NULL;
  /* the crop box, already intersected with the media box; a missing media box is US Letter */
  CGRect media = CGPDFPageGetBoxRect(p, kCGPDFMediaBox);
  CGRect box = CGPDFPageGetBoxRect(p, kCGPDFCropBox);
  if (CGRectIsEmpty(media)) box = CGRectMake(0, 0, 612, 792);
  fz_figure *f = fz_malloc_struct(ctx, fz_figure);
  f->refs = 1;
  f->path = fz_strdup(ctx, path);
  f->page = page;
  f->box = fz_make_rect(CGRectGetMinX(box), CGRectGetMinY(box), CGRectGetMaxX(box), CGRectGetMaxY(box));
  f->rotate = ((CGPDFPageGetRotationAngle(p) % 360) + 360) % 360;
  return f;
}

fz_figure *fz_keep_figure(fz_context *ctx, fz_figure *f) { (void)ctx; if (f) f->refs++; return f; }

void fz_drop_figure(fz_context *ctx, fz_figure *f)
{
  (void)ctx;
  if (!f || --f->refs > 0) return;
  free(f->path);
  free(f);
}

/* PDF space (y up) → the page as shown: turned clockwise by /Rotate, y down, the box's top-left corner at (0, 0). */
fz_matrix fz_figure_page_ctm(fz_figure *f)
{
  fz_matrix m = fz_concat(fz_rotate((float)-f->rotate), fz_scale(1, -1));
  fz_rect r = fz_transform_rect(f->box, m);
  return fz_concat(m, fz_translate(-r.x0, -r.y0));
}

/* ---- CMYK --------------------------------------------------------------------------------------------------------- */

/* As PDF viewers show it: a measured 9^4 grid (gen_cmyk.py), interpolated linearly in all four directions. */
#include "cmyk_table.h"

void rt_cmyk_to_rgb(const float cmyk[4], float rgb[3])
{
  int i0[4];
  float f[4];
  for (int j = 0; j < 4; j++)
  {
    float t = fz_clamp(cmyk[j], 0, 1) * 8;
    int i = (int)t;
    if (i > 7) i = 7;
    i0[j] = i;
    f[j] = t - i;
  }
  float acc[3] = {0, 0, 0};
  for (int corner = 0; corner < 16; corner++)
  {
    float w = 1;
    int idx = 0;
    for (int j = 0; j < 4; j++)
    {
      int bit = (corner >> (3 - j)) & 1;
      w *= bit ? f[j] : 1 - f[j];
      idx = idx * 9 + i0[j] + bit;
    }
    if (w == 0) continue;
    for (int k = 0; k < 3; k++) acc[k] += w * cmyk_table[idx][k];
  }
  for (int k = 0; k < 3; k++) rgb[k] = fz_clamp(acc[k] / 255, 0, 1);
}

#include "mupdf/pdf.h"

pdf_document *pdf_open_document_with_stream(fz_context *ctx, fz_stream *stm)
{
  const char *path = fz_stream_filename(stm);
  if (!path) fz_throw(ctx, FZ_ERROR_ARGUMENT, "figure: not a file");
  rt_forget_figure_file(path); /* opened again: the file may have changed */
  int n = fz_figure_page_count(ctx, path);
  if (n < 1) fz_throw(ctx, FZ_ERROR_FORMAT, "figure: cannot open %s as a PDF", path);
  pdf_document *d = fz_malloc_struct(ctx, pdf_document);
  d->path = fz_strdup(ctx, path);
  d->pages = n;
  return d;
}

void pdf_drop_document(fz_context *ctx, pdf_document *d)
{
  if (!d) return;
  rt_forget_figure_file(d->path);
  fz_free(ctx, d->path);
  fz_free(ctx, d);
}
