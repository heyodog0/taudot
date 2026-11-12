// ["dlist", id, page, out_path]: a page's vector display list in Taudot's format (dlist.md).
//
// Included by txp-render.c after glyphs.c: txp-headless's statics (ctx, out, page_dl, ...) and the cursor agent's
// glyph_text / glyph_ink are in scope.
//
// The interpreter's page list (rt/, Taudot's runtime) runs through a recording device that writes our format. The
// bytes are kept per page: the `render` verb draws tiles from them (TaudotRender, swift/).
//
// Answer: {"id":ID,"ok":true,"bytes":N,"ops":K,"fonts":F,"us":T}

#include <sys/stat.h>

// ---- a growable byte buffer ----------------------------------------------------------------------------------------

typedef struct { unsigned char *p; size_t n, cap; } tdl_buf;

static void tb_need(tdl_buf *b, size_t k)
{
  if (b->n + k <= b->cap) return;
  size_t c = b->cap ? b->cap * 2 : 65536;
  while (c < b->n + k) c *= 2;
  b->p = realloc(b->p, c);
  b->cap = c;
}
static void tb_bytes(tdl_buf *b, const void *s, size_t k) { tb_need(b, k); memcpy(b->p + b->n, s, k); b->n += k; }
static void tb_u8(tdl_buf *b, unsigned v) { unsigned char c = v; tb_bytes(b, &c, 1); }
static void tb_u16(tdl_buf *b, unsigned v) { unsigned char c[2] = {v & 255, (v >> 8) & 255}; tb_bytes(b, c, 2); }
static void tb_u32(tdl_buf *b, uint32_t v)
{
  unsigned char c[4] = {v & 255, (v >> 8) & 255, (v >> 16) & 255, v >> 24};
  tb_bytes(b, c, 4);
}
static void tb_f32(tdl_buf *b, float f) { uint32_t v; memcpy(&v, &f, 4); tb_u32(b, v); }
static void tb_str(tdl_buf *b, const char *s)
{
  size_t k = strlen(s);
  if (k > 65535) k = 65535;
  tb_u16(b, k);
  tb_bytes(b, s, k);
}
static void tb_put_u32_at(tdl_buf *b, size_t at, uint32_t v)
{
  unsigned char c[4] = {v & 255, (v >> 8) & 255, (v >> 16) & 255, v >> 24};
  memcpy(b->p + at, c, 4);
}

// a record: kind, then a u32 length patched by rec_end
static size_t rec_begin(tdl_buf *b, unsigned kind)
{
  tb_u8(b, kind);
  size_t at = b->n;
  tb_u32(b, 0);
  return at;
}
static void rec_end(tdl_buf *b, size_t at) { tb_put_u32_at(b, at, (uint32_t)(b->n - at - 4)); }

enum
{
  TDL_END = 0x00, TDL_PAGE = 0x01, TDL_FONT = 0x02, TDL_IMAGE = 0x03,
  TDL_TEXT = 0x10, TDL_FILL = 0x11, TDL_STROKE = 0x12, TDL_RULE = 0x13, TDL_DRAW_IMAGE = 0x14, TDL_IMAGE_MASK = 0x15, TDL_SHADE = 0x16,
  TDL_FIGURE = 0x17,
  TDL_CLIP_PATH = 0x20, TDL_CLIP_STROKE = 0x21, TDL_CLIP_IMAGE_MASK = 0x22, TDL_POP_CLIP = 0x2f,
  TDL_BEGIN_GROUP = 0x30, TDL_END_GROUP = 0x31, TDL_BEGIN_MASK = 0x32, TDL_END_MASK = 0x33,
  TDL_BEGIN_TILE = 0x34, TDL_END_TILE = 0x35, TDL_UNSUPPORTED = 0x3f,
};
enum { TEXT_FILL = 0, TEXT_STROKE = 1, TEXT_CLIP = 3, TEXT_INVISIBLE = 4 };
enum { FONT_SFNT = 1, FONT_OUTLINES = 2, FONT_MISSING = 3 };
enum { IMG_PNG = 1, IMG_JPEG = 2, IMG_RGBA = 3 };

// ---- the recording device ------------------------------------------------------------------------------------------

#define TDL_MAX_FONTS 256
#define TDL_MAX_IMAGES 256

typedef struct
{
  fz_font *font;
  int type;
  int *gids; // outline fonts: the glyphs used on this page
  int ngids, capgids;
} tdl_font;

typedef struct
{
  fz_device base;
  tdl_buf ops;
  int nops;
  tdl_font fonts[TDL_MAX_FONTS];
  int nfonts;
  fz_image *images[TDL_MAX_IMAGES];
  bool as_mask[TDL_MAX_IMAGES]; // used as a clip or stencil: coverage in alpha
  int nimages;
  glyph_dev *ink; // glyphs.c's ink-box cache (only its table is used)
} tdl_dev;

static void put_rect(tdl_buf *b, fz_rect r)
{
  if (fz_is_empty_rect(r)) r = fz_make_rect(0, 0, 0, 0);
  if (fz_is_infinite_rect(r)) r = fz_make_rect(-1e6f, -1e6f, 1e6f, 1e6f);
  tb_f32(b, r.x0); tb_f32(b, r.y0); tb_f32(b, r.x1); tb_f32(b, r.y1);
}
static void put_matrix(tdl_buf *b, fz_matrix m)
{
  tb_f32(b, m.a); tb_f32(b, m.b); tb_f32(b, m.c); tb_f32(b, m.d); tb_f32(b, m.e); tb_f32(b, m.f);
}
static void put_rgba(tdl_buf *b, fz_colorspace *cs, const float *color, float alpha, fz_color_params cp)
{
  float rgb[3] = {0, 0, 0};
  if (cs && color) fz_convert_color(ctx, cs, color, fz_device_rgb(ctx), rgb, NULL, cp);
  for (int i = 0; i < 3; i++) tb_f32(b, rgb[i] < 0 ? 0 : rgb[i] > 1 ? 1 : rgb[i]);
  tb_f32(b, alpha);
}

// paths: commands and coordinates collected by a walker, then written as one block
typedef struct { tdl_buf cmd, coord; int ncoord; float cx, cy, sx, sy; } path_rec;

static void pr_pt(path_rec *r, float x, float y) { tb_f32(&r->coord, x); tb_f32(&r->coord, y); r->ncoord += 2; }
static void pw_move(fz_context *c, void *a, float x, float y)
{ (void)c; path_rec *r = a; tb_u8(&r->cmd, 'M'); pr_pt(r, x, y); r->cx = r->sx = x; r->cy = r->sy = y; }
static void pw_line(fz_context *c, void *a, float x, float y)
{ (void)c; path_rec *r = a; tb_u8(&r->cmd, 'L'); pr_pt(r, x, y); r->cx = x; r->cy = y; }
static void pw_curve(fz_context *c, void *a, float x1, float y1, float x2, float y2, float x3, float y3)
{
  (void)c; path_rec *r = a;
  tb_u8(&r->cmd, 'C'); pr_pt(r, x1, y1); pr_pt(r, x2, y2); pr_pt(r, x3, y3);
  r->cx = x3; r->cy = y3;
}
static void pw_close(fz_context *c, void *a) { (void)c; path_rec *r = a; tb_u8(&r->cmd, 'Z'); r->cx = r->sx; r->cy = r->sy; }
static void pw_quad(fz_context *c, void *a, float x1, float y1, float x2, float y2)
{ (void)c; path_rec *r = a; tb_u8(&r->cmd, 'Q'); pr_pt(r, x1, y1); pr_pt(r, x2, y2); r->cx = x2; r->cy = y2; }
static void pw_curvev(fz_context *c, void *a, float x2, float y2, float x3, float y3)
{ path_rec *r = a; pw_curve(c, a, r->cx, r->cy, x2, y2, x3, y3); }
static void pw_curvey(fz_context *c, void *a, float x1, float y1, float x3, float y3)
{ pw_curve(c, a, x1, y1, x3, y3, x3, y3); }
static void pw_rect(fz_context *c, void *a, float x1, float y1, float x2, float y2)
{
  pw_move(c, a, x1, y1); pw_line(c, a, x2, y1); pw_line(c, a, x2, y2); pw_line(c, a, x1, y2); pw_close(c, a);
}
static const fz_path_walker tdl_walker = {pw_move, pw_line, pw_curve, pw_close, pw_quad, pw_curvev, pw_curvey, pw_rect};

static void pr_free(path_rec *r) { free(r->cmd.p); free(r->coord.p); }

static void pr_walk(path_rec *r, const fz_path *path)
{
  memset(r, 0, sizeof *r);
  fz_walk_path(ctx, path, &tdl_walker, r);
}

static void put_path_rec(tdl_buf *b, path_rec *r)
{
  tb_u32(b, (uint32_t)r->cmd.n);
  tb_u32(b, (uint32_t)r->ncoord);
  tb_bytes(b, r->cmd.p, r->cmd.n);
  tb_bytes(b, r->coord.p, r->coord.n);
}

static void put_path(tdl_buf *b, const fz_path *path)
{
  path_rec r;
  pr_walk(&r, path);
  put_path_rec(b, &r);
  pr_free(&r);
}

static void put_stroke(tdl_buf *b, const fz_stroke_state *s)
{
  tb_f32(b, s->linewidth);
  tb_u8(b, s->start_cap);
  tb_u8(b, s->linejoin == FZ_LINEJOIN_MITER_XPS ? FZ_LINEJOIN_MITER : s->linejoin);
  tb_f32(b, s->miterlimit);
  tb_f32(b, s->dash_phase);
  int n = s->dash_len > 0 ? s->dash_len : 0;
  tb_u16(b, n);
  for (int i = 0; i < n; i++) tb_f32(b, s->dash_list[i]);
}

/** A filled path that is one axis-aligned rectangle on the page: its page rect. */
static bool path_is_rule(path_rec *r, fz_matrix m, fz_rect *out_rect)
{
  const unsigned char *c = r->cmd.p;
  int nc = (int)r->cmd.n;
  if (!(nc == 5 && c[0] == 'M' && c[1] == 'L' && c[2] == 'L' && c[3] == 'L' && c[4] == 'Z') &&
      !(nc == 4 && c[0] == 'M' && c[1] == 'L' && c[2] == 'L' && c[3] == 'L') &&
      !(nc == 5 && c[0] == 'M' && c[1] == 'L' && c[2] == 'L' && c[3] == 'L' && c[4] == 'L'))
    return false;
  float v[10];
  memcpy(v, r->coord.p, (nc == 5 && c[4] == 'L' ? 10 : 8) * sizeof(float));
  fz_point p[4];
  for (int i = 0; i < 4; i++) p[i] = fz_transform_point(fz_make_point(v[2 * i], v[2 * i + 1]), m);
  if (nc == 5 && c[4] == 'L')
  {
    fz_point q = fz_transform_point(fz_make_point(v[8], v[9]), m);
    if (fabsf(q.x - p[0].x) > 1e-3f || fabsf(q.y - p[0].y) > 1e-3f) return false;
  }
  const float e = 1e-3f;
  for (int i = 0; i < 4; i++)
  {
    fz_point a = p[i], b = p[(i + 1) & 3];
    if (fabsf(a.x - b.x) > e && fabsf(a.y - b.y) > e) return false;
  }
  // alternating: two horizontal and two vertical sides
  bool h0 = fabsf(p[0].y - p[1].y) <= e, h1 = fabsf(p[1].y - p[2].y) <= e;
  if (h0 == h1) return false;
  fz_rect rr = fz_empty_rect;
  for (int i = 0; i < 4; i++) rr = fz_include_point_in_rect(rr, p[i]);
  *out_rect = rr;
  return true;
}

// ---- fonts and images ----------------------------------------------------------------------------------------------

static bool is_sfnt(fz_buffer *b)
{
  if (!b || b->len < 12) return false;
  const unsigned char *d = b->data;
  return !memcmp(d, "OTTO", 4) || !memcmp(d, "\0\1\0\0", 4) || !memcmp(d, "true", 4) || !memcmp(d, "ttcf", 4);
}

static int tdl_font_index(tdl_dev *d, fz_font *font)
{
  for (int i = 0; i < d->nfonts; i++)
    if (d->fonts[i].font == font) return i;
  if (d->nfonts == TDL_MAX_FONTS) return -1;
  tdl_font *f = &d->fonts[d->nfonts];
  memset(f, 0, sizeof *f);
  f->font = font;
  f->type = is_sfnt(font->buffer) ? FONT_SFNT : FONT_OUTLINES;
  return d->nfonts++;
}

static void font_use_gid(tdl_font *f, int gid)
{
  if (f->type != FONT_OUTLINES) return;
  for (int i = 0; i < f->ngids; i++)
    if (f->gids[i] == gid) return;
  if (f->ngids == f->capgids)
  {
    f->capgids = f->capgids ? f->capgids * 2 : 64;
    f->gids = realloc(f->gids, f->capgids * sizeof *f->gids);
  }
  f->gids[f->ngids++] = gid;
}

// font files written this process, by content hash
static uint64_t written_fonts[1024];
static int nwritten_fonts;

/** The sfnt's bytes on disk, once per process: $TMPDIR/taudot-fonts/<hash>.otf */
static bool font_file(fz_buffer *b, char *path, size_t cap)
{
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0; i < b->len; i++) { h ^= b->data[i]; h *= 1099511628211ULL; }
  const char *tmp = getenv("TMPDIR");
  char dir[1024];
  snprintf(dir, sizeof dir, "%s/taudot-fonts", tmp && tmp[0] ? tmp : "/tmp");
  bool ttc = !memcmp(b->data, "ttcf", 4), ttf = !memcmp(b->data, "\0\1\0\0", 4) || !memcmp(b->data, "true", 4);
  snprintf(path, cap, "%s/%016llx.%s", dir, (unsigned long long)h, ttc ? "ttc" : ttf ? "ttf" : "otf");
  for (int i = 0; i < nwritten_fonts; i++)
    if (written_fonts[i] == h) return true;
  struct stat s;
  if (stat(path, &s) != 0 || s.st_size != (off_t)b->len)
  {
    mkdir(dir, 0755);
    char part[1100];
    snprintf(part, sizeof part, "%s.%d.part", path, (int)getpid());
    FILE *f = fopen(part, "wb");
    if (!f) return false;
    bool ok = fwrite(b->data, 1, b->len, f) == b->len;
    ok = fclose(f) == 0 && ok;
    if (!ok || rename(part, path) != 0) { unlink(part); return false; }
  }
  if (nwritten_fonts < 1024) written_fonts[nwritten_fonts++] = h;
  return true;
}

static void write_font(tdl_buf *b, int id, tdl_font *f)
{
  size_t at = rec_begin(b, TDL_FONT);
  tb_u32(b, id);
  char path[1200];
  int type = f->type;
  if (type == FONT_SFNT && !font_file(f->font->buffer, path, sizeof path)) type = FONT_OUTLINES;
  tb_u8(b, type);
  tb_str(b, fz_font_name(ctx, f->font));
  if (type == FONT_SFNT)
  {
    tb_str(b, path);
    tb_u32(b, (uint32_t)(f->font->index & 0xffff));
  }
  else if (type == FONT_OUTLINES)
  {
    tb_u32(b, f->ngids);
    for (int i = 0; i < f->ngids; i++)
    {
      tb_u32(b, f->gids[i]);
      fz_path *p = NULL;
      fz_try(ctx) p = fz_outline_glyph(ctx, f->font, f->gids[i], fz_identity);
      fz_catch(ctx) p = NULL;
      if (p) { put_path(b, p); fz_drop_path(ctx, p); }
      else { tb_u32(b, 0); tb_u32(b, 0); }
    }
  }
  rec_end(b, at);
}

static int tdl_image_index(tdl_dev *d, fz_image *img, bool as_mask)
{
  for (int i = 0; i < d->nimages; i++)
    if (d->images[i] == img && d->as_mask[i] == as_mask) return i;
  if (d->nimages == TDL_MAX_IMAGES) return -1;
  d->images[d->nimages] = fz_keep_image(ctx, img);
  d->as_mask[d->nimages] = as_mask;
  return d->nimages++;
}

/** An image as PNG/JPEG bytes when it is a plain file of one (Gray or RGB), else decoded to RGBA8 by ImageIO. File
 *  images are never masks; a mask (as_mask) would carry its coverage in alpha. */
static void write_image(tdl_buf *b, int id, fz_image *img, bool as_mask)
{
  size_t at = rec_begin(b, TDL_IMAGE);
  tb_u32(b, id);
  if (!as_mask && img->buffer && (img->n == 1 || img->n == 3) &&
      (img->type == FZ_IMAGE_JPEG || img->type == FZ_IMAGE_PNG))
  {
    tb_u32(b, img->w);
    tb_u32(b, img->h);
    tb_u8(b, img->type == FZ_IMAGE_JPEG ? IMG_JPEG : IMG_PNG);
    tb_u32(b, (uint32_t)img->buffer->len);
    tb_bytes(b, img->buffer->data, img->buffer->len);
    rec_end(b, at);
    return;
  }
  int w = 0, h = 0;
  unsigned char *px = fz_image_rgba(ctx, img, &w, &h);
  if (!px) w = h = 0;
  tb_u32(b, w);
  tb_u32(b, h);
  tb_u8(b, IMG_RGBA);
  tb_u32(b, (uint32_t)w * h * 4);
  if (px && as_mask)
    for (size_t i = 0; i < (size_t)w * h; i++)
    {
      // a soft mask: its grey is the coverage
      unsigned char *p = px + i * 4;
      int g = (p[0] * 77 + p[1] * 151 + p[2] * 28) >> 8;
      p[0] = p[1] = p[2] = 0;
      p[3] = g * p[3] / 255;
    }
  if (px) tb_bytes(b, px, (size_t)w * h * 4);
  free(px);
  rec_end(b, at);
}

// ---- device callbacks ----------------------------------------------------------------------------------------------

static size_t op_begin(tdl_dev *d, unsigned kind, fz_rect bbox)
{
  size_t at = rec_begin(&d->ops, kind);
  put_rect(&d->ops, bbox);
  d->nops++;
  return at;
}

static void op_unsupported(tdl_dev *d, fz_rect bbox, const char *what)
{
  size_t at = op_begin(d, TDL_UNSUPPORTED, bbox);
  tb_str(&d->ops, what);
  rec_end(&d->ops, at);
}

static void tdl_fill_path(fz_context *c, fz_device *dev, const fz_path *path, int eo, fz_matrix m, fz_colorspace *cs,
                          const float *color, float alpha, fz_color_params cp)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  path_rec r;
  pr_walk(&r, path);
  fz_rect rule;
  if (path_is_rule(&r, m, &rule))
  {
    size_t at = op_begin(d, TDL_RULE, rule);
    put_rgba(&d->ops, cs, color, alpha, cp);
    rec_end(&d->ops, at);
  }
  else
  {
    size_t at = op_begin(d, TDL_FILL, fz_bound_path(ctx, path, NULL, m));
    tb_u8(&d->ops, eo ? 1 : 0);
    put_rgba(&d->ops, cs, color, alpha, cp);
    put_matrix(&d->ops, m);
    put_path_rec(&d->ops, &r);
    rec_end(&d->ops, at);
  }
  pr_free(&r);
}

static void tdl_stroke_path(fz_context *c, fz_device *dev, const fz_path *path, const fz_stroke_state *ss, fz_matrix m,
                            fz_colorspace *cs, const float *color, float alpha, fz_color_params cp)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  size_t at = op_begin(d, TDL_STROKE, fz_bound_path(ctx, path, ss, m));
  put_rgba(&d->ops, cs, color, alpha, cp);
  put_matrix(&d->ops, m);
  put_stroke(&d->ops, ss);
  put_path(&d->ops, path);
  rec_end(&d->ops, at);
}

static void tdl_clip_path(fz_context *c, fz_device *dev, const fz_path *path, int eo, fz_matrix m, fz_rect scissor)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  size_t at = op_begin(d, TDL_CLIP_PATH, fz_intersect_rect(fz_bound_path(ctx, path, NULL, m), scissor));
  tb_u8(&d->ops, eo ? 1 : 0);
  put_matrix(&d->ops, m);
  put_path(&d->ops, path);
  rec_end(&d->ops, at);
}

static void tdl_clip_stroke_path(fz_context *c, fz_device *dev, const fz_path *path, const fz_stroke_state *ss,
                                 fz_matrix m, fz_rect scissor)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  size_t at = op_begin(d, TDL_CLIP_STROKE, fz_intersect_rect(fz_bound_path(ctx, path, ss, m), scissor));
  put_matrix(&d->ops, m);
  put_stroke(&d->ops, ss);
  put_path(&d->ops, path);
  rec_end(&d->ops, at);
}

/** One TEXT op per span (a span has one font and one matrix). */
static void tdl_text(tdl_dev *d, const fz_text *text, fz_matrix ctm, int mode, const fz_stroke_state *ss,
                     fz_colorspace *cs, const float *color, float alpha, fz_color_params cp)
{
  for (fz_text_span *sp = text->head; sp; sp = sp->next)
  {
    int fi = tdl_font_index(d, sp->font);
    if (fi < 0) continue;
    tdl_font *f = &d->fonts[fi];
    fz_matrix lin = fz_concat(fz_make_matrix(sp->trm.a, sp->trm.b, sp->trm.c, sp->trm.d, 0, 0),
                              fz_make_matrix(ctm.a, ctm.b, ctm.c, ctm.d, 0, 0));
    // the bbox, from each glyph's ink: computed first, the op is written once
    fz_rect bbox = fz_empty_rect;
    int count = 0;
    for (int k = 0; k < sp->len; k++)
    {
      const fz_text_item *it = &sp->items[k];
      if (it->gid < 0) continue;
      count++;
      fz_point o = fz_transform_point(fz_make_point(it->x, it->y), ctm);
      fz_matrix m = lin;
      m.e = o.x;
      m.f = o.y;
      fz_rect ink = glyph_ink(ctx, d->ink, sp->font, it->gid);
      if (fz_is_empty_rect(ink) || fz_is_infinite_rect(ink))
        ink = fz_make_rect(0, -0.25f, fz_advance_glyph(ctx, sp->font, it->gid, sp->wmode), 0.75f);
      bbox = fz_union_rect(bbox, fz_transform_rect(ink, m));
    }
    if (!count) continue;
    size_t at = op_begin(d, TDL_TEXT, bbox);
    tb_u8(&d->ops, mode);
    put_rgba(&d->ops, cs, color, alpha, cp);
    if (mode == TEXT_STROKE) put_stroke(&d->ops, ss);
    tb_u32(&d->ops, fi);
    tb_f32(&d->ops, lin.a); tb_f32(&d->ops, lin.b); tb_f32(&d->ops, lin.c); tb_f32(&d->ops, lin.d);
    tb_u32(&d->ops, count);
    for (int k = 0; k < sp->len; k++)
    {
      const fz_text_item *it = &sp->items[k];
      if (it->gid < 0) continue;
      fz_point o = fz_transform_point(fz_make_point(it->x, it->y), ctm);
      float adv = fz_advance_glyph(ctx, sp->font, it->gid, sp->wmode);
      fz_point av = fz_transform_vector(sp->wmode ? fz_make_point(0, adv) : fz_make_point(adv, 0), lin);
      char t[64];
      glyph_text(ctx, sp->font, it, t);
      tb_u32(&d->ops, it->gid);
      tb_f32(&d->ops, o.x);
      tb_f32(&d->ops, o.y);
      tb_f32(&d->ops, sqrtf(av.x * av.x + av.y * av.y));
      tb_str(&d->ops, t);
      font_use_gid(f, it->gid);
    }
    rec_end(&d->ops, at);
  }
}

static void tdl_fill_text(fz_context *c, fz_device *dev, const fz_text *text, fz_matrix m, fz_colorspace *cs,
                          const float *color, float alpha, fz_color_params cp)
{ (void)c; tdl_text((tdl_dev *)dev, text, m, TEXT_FILL, NULL, cs, color, alpha, cp); }
static void tdl_stroke_text(fz_context *c, fz_device *dev, const fz_text *text, const fz_stroke_state *ss, fz_matrix m,
                            fz_colorspace *cs, const float *color, float alpha, fz_color_params cp)
{ (void)c; tdl_text((tdl_dev *)dev, text, m, TEXT_STROKE, ss, cs, color, alpha, cp); }
static void tdl_clip_text(fz_context *c, fz_device *dev, const fz_text *text, fz_matrix m, fz_rect scissor)
{ (void)c; (void)scissor; tdl_text((tdl_dev *)dev, text, m, TEXT_CLIP, NULL, NULL, NULL, 1, fz_default_color_params); }
static void tdl_clip_stroke_text(fz_context *c, fz_device *dev, const fz_text *text, const fz_stroke_state *ss,
                                 fz_matrix m, fz_rect scissor)
{ (void)c; (void)ss; (void)scissor; tdl_text((tdl_dev *)dev, text, m, TEXT_CLIP, NULL, NULL, NULL, 1, fz_default_color_params); }
static void tdl_ignore_text(fz_context *c, fz_device *dev, const fz_text *text, fz_matrix m)
{ (void)c; tdl_text((tdl_dev *)dev, text, m, TEXT_INVISIBLE, NULL, NULL, NULL, 1, fz_default_color_params); }

/** Axial and radial shadings as SHADE: geometry, extends, and the colour function sampled at 256 points in sRGB.
 *  Function-based and mesh shadings stay UNSUPPORTED. */
static void tdl_fill_shade(fz_context *c, fz_device *dev, fz_shade *shd, fz_matrix m, float alpha, fz_color_params cp)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  fz_rect bbox = fz_bound_shade(ctx, shd, m);
  int n = shd->colorspace ? fz_colorspace_n(ctx, shd->colorspace) : 0;
  if ((shd->type != FZ_LINEAR && shd->type != FZ_RADIAL) || !shd->function_stride || !shd->function || n < 1 ||
      shd->function_stride < n)
  {
    op_unsupported(d, bbox, shd->type == FZ_FUNCTION_BASED ? "shade: function" : "shade: mesh");
    return;
  }
  size_t at = op_begin(d, TDL_SHADE, bbox);
  tb_u8(&d->ops, shd->type == FZ_LINEAR ? 2 : 3);
  tb_u8(&d->ops, shd->u.l_or_r.extend[0] ? 1 : 0);
  tb_u8(&d->ops, shd->u.l_or_r.extend[1] ? 1 : 0);
  for (int i = 0; i < 2; i++)
    for (int k = 0; k < 3; k++) tb_f32(&d->ops, shd->u.l_or_r.coords[i][k]);
  put_matrix(&d->ops, fz_concat(shd->matrix, m));  // shading space → page
  // the shading's own bbox (shading space), empty when it has none
  fz_rect sb = fz_is_infinite_rect(shd->bbox) ? fz_empty_rect : shd->bbox;
  put_rect(&d->ops, sb);
  tb_f32(&d->ops, alpha);
  tb_u16(&d->ops, 256);
  for (int i = 0; i < 256; i++)
  {
    const float *f = shd->function + (size_t)i * shd->function_stride;
    float rgb[3] = {0, 0, 0};
    fz_convert_color(ctx, shd->colorspace, f, fz_device_rgb(ctx), rgb, NULL, cp);
    float a = shd->function_stride > n ? f[n] : 1;
    for (int k = 0; k < 3; k++) tb_u8(&d->ops, (unsigned)(fminf(fmaxf(rgb[k], 0), 1) * 255 + 0.5f));
    tb_u8(&d->ops, (unsigned)(fminf(fmaxf(a, 0), 1) * 255 + 0.5f));
  }
  rec_end(&d->ops, at);
}

static void tdl_fill_image(fz_context *c, fz_device *dev, fz_image *img, fz_matrix m, float alpha, fz_color_params cp)
{
  (void)c; (void)cp;
  tdl_dev *d = (tdl_dev *)dev;
  int ii = tdl_image_index(d, img, false);
  fz_rect bbox = fz_transform_rect(fz_unit_rect, m);
  if (ii < 0) { op_unsupported(d, bbox, "too many images"); return; }
  size_t at = op_begin(d, TDL_DRAW_IMAGE, bbox);
  tb_f32(&d->ops, alpha);
  put_matrix(&d->ops, m);
  tb_u32(&d->ops, ii);
  rec_end(&d->ops, at);
}

static void tdl_fill_image_mask(fz_context *c, fz_device *dev, fz_image *img, fz_matrix m, fz_colorspace *cs,
                                const float *color, float alpha, fz_color_params cp)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  int ii = tdl_image_index(d, img, true);
  fz_rect bbox = fz_transform_rect(fz_unit_rect, m);
  if (ii < 0) { op_unsupported(d, bbox, "too many images"); return; }
  size_t at = op_begin(d, TDL_IMAGE_MASK, bbox);
  put_rgba(&d->ops, cs, color, alpha, cp);
  put_matrix(&d->ops, m);
  tb_u32(&d->ops, ii);
  rec_end(&d->ops, at);
}

static void tdl_clip_image_mask(fz_context *c, fz_device *dev, fz_image *img, fz_matrix m, fz_rect scissor)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  int ii = tdl_image_index(d, img, true);
  size_t at = op_begin(d, TDL_CLIP_IMAGE_MASK, fz_intersect_rect(fz_transform_rect(fz_unit_rect, m), scissor));
  put_matrix(&d->ops, m);
  tb_u32(&d->ops, ii < 0 ? 0 : ii);
  rec_end(&d->ops, at);
}

static void tdl_pop_clip(fz_context *c, fz_device *dev)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  rec_end(&d->ops, op_begin(d, TDL_POP_CLIP, fz_empty_rect));
}

static void tdl_begin_mask(fz_context *c, fz_device *dev, fz_rect area, int luminosity, fz_colorspace *cs,
                           const float *bc, fz_color_params cp)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  size_t at = op_begin(d, TDL_BEGIN_MASK, area);
  tb_u8(&d->ops, luminosity ? 1 : 0);
  float rgb[3] = {0, 0, 0};
  if (cs && bc) fz_convert_color(ctx, cs, bc, fz_device_rgb(ctx), rgb, NULL, cp);
  for (int i = 0; i < 3; i++) tb_f32(&d->ops, rgb[i]);
  rec_end(&d->ops, at);
}

static void tdl_end_mask(fz_context *c, fz_device *dev, fz_function *fn)
{
  (void)c; (void)fn; // transfer functions: not yet (rare in TeX output)
  tdl_dev *d = (tdl_dev *)dev;
  rec_end(&d->ops, op_begin(d, TDL_END_MASK, fz_empty_rect));
}

static void tdl_begin_group(fz_context *c, fz_device *dev, fz_rect area, fz_colorspace *cs, int isolated, int knockout,
                            int blend, float alpha)
{
  (void)c; (void)cs;
  tdl_dev *d = (tdl_dev *)dev;
  size_t at = op_begin(d, TDL_BEGIN_GROUP, area);
  tb_u8(&d->ops, isolated ? 1 : 0);
  tb_u8(&d->ops, knockout ? 1 : 0);
  tb_u8(&d->ops, blend);
  tb_f32(&d->ops, alpha);
  rec_end(&d->ops, at);
}

static void tdl_end_group(fz_context *c, fz_device *dev)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  rec_end(&d->ops, op_begin(d, TDL_END_GROUP, fz_empty_rect));
}

/** A page of an included PDF: FIGURE, drawn by Core Graphics from the file. */
static void tdl_fill_figure(fz_context *c, fz_device *dev, fz_figure *fig, fz_matrix m)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  size_t at = op_begin(d, TDL_FIGURE, fz_transform_rect(fig->box, m));
  put_matrix(&d->ops, m);
  put_rect(&d->ops, fig->box);
  tb_u32(&d->ops, fig->page);
  tb_str(&d->ops, fig->path);
  rec_end(&d->ops, at);
}

static int tdl_begin_tile(fz_context *c, fz_device *dev, fz_rect area, fz_rect view, float xstep, float ystep,
                          fz_matrix m, int id, int doc_id)
{
  (void)c; (void)id; (void)doc_id;
  tdl_dev *d = (tdl_dev *)dev;
  size_t at = op_begin(d, TDL_BEGIN_TILE, fz_transform_rect(area, m));
  put_rect(&d->ops, area);
  put_rect(&d->ops, view);
  tb_f32(&d->ops, xstep);
  tb_f32(&d->ops, ystep);
  put_matrix(&d->ops, m);
  rec_end(&d->ops, at);
  return 0; // the tile's content follows once, in tile space
}

static void tdl_end_tile(fz_context *c, fz_device *dev)
{
  (void)c;
  tdl_dev *d = (tdl_dev *)dev;
  rec_end(&d->ops, op_begin(d, TDL_END_TILE, fz_empty_rect));
}

static tdl_dev *new_tdl_dev(void)
{
  tdl_dev *d = fz_new_derived_device(ctx, tdl_dev);
  d->base.fill_path = tdl_fill_path;
  d->base.stroke_path = tdl_stroke_path;
  d->base.clip_path = tdl_clip_path;
  d->base.clip_stroke_path = tdl_clip_stroke_path;
  d->base.fill_text = tdl_fill_text;
  d->base.stroke_text = tdl_stroke_text;
  d->base.clip_text = tdl_clip_text;
  d->base.clip_stroke_text = tdl_clip_stroke_text;
  d->base.ignore_text = tdl_ignore_text;
  d->base.fill_shade = tdl_fill_shade;
  d->base.fill_image = tdl_fill_image;
  d->base.fill_image_mask = tdl_fill_image_mask;
  d->base.clip_image_mask = tdl_clip_image_mask;
  d->base.pop_clip = tdl_pop_clip;
  d->base.begin_mask = tdl_begin_mask;
  d->base.end_mask = tdl_end_mask;
  d->base.begin_group = tdl_begin_group;
  d->base.end_group = tdl_end_group;
  d->base.begin_tile = tdl_begin_tile;
  d->base.end_tile = tdl_end_tile;
  d->base.fill_figure = tdl_fill_figure;
  return d;
}

// glyphs.c's ink cache, kept for the process: ink boxes don't change while a font lives. A font freed and another
// allocated at its address would get stale boxes, so the cache is cleared whenever the page list is rebuilt from 0.
static glyph_dev *tdl_ink;

static void free_tdl_dev(tdl_dev *d)
{
  free(d->ops.p);
  for (int i = 0; i < d->nfonts; i++) free(d->fonts[i].gids);
  for (int i = 0; i < d->nimages; i++) fz_drop_image(ctx, d->images[i]);
  fz_drop_device(ctx, &d->base);
}

/** The whole list: header, PAGE, FONTs, IMAGEs, the ops, END. */
static void make_tdl(tdl_buf *b, int page, fz_rect bounds, tdl_dev *d)
{
  tb_bytes(b, "TDL\0", 4);
  tb_u32(b, 2);
  size_t at = rec_begin(b, TDL_PAGE);
  tb_u32(b, page);
  tb_f32(b, bounds.x1 - bounds.x0);
  tb_f32(b, bounds.y1 - bounds.y0);
  rec_end(b, at);
  for (int i = 0; i < d->nfonts; i++) write_font(b, i, &d->fonts[i]);
  for (int i = 0; i < d->nimages; i++) write_image(b, i, d->images[i], d->as_mask[i]);
  tb_bytes(b, d->ops.p, d->ops.n);
  rec_end(b, rec_begin(b, TDL_END));
}

// per page: the list's bytes, made from this display list (kept, so its address can't come back for another page)
typedef struct { fz_display_list *dl; tdl_buf b; uint64_t key; int ops, fonts; int64_t us; } tdl_cached;
static tdl_cached tdl_cache[MAX_PAGES];

static tdl_cached *page_tdl_cached(int page, const char **err)
{
  *err = "no page";
  fz_display_list *dl = page_dl(page);
  if (!dl) return NULL;
  tdl_cached *c = &tdl_cache[page];
  if (c->dl == dl && c->b.p) return c;
  int64_t t0 = now_us();
  if (!tdl_ink) tdl_ink = fz_malloc_struct(ctx, glyph_dev);
  else if (dl_count <= 1) memset(tdl_ink->ink, 0, sizeof tdl_ink->ink);
  fz_rect b = fz_bound_display_list(ctx, dl);
  tdl_dev *d = new_tdl_dev();
  d->ink = tdl_ink;
  bool ok = true;
  fz_try(ctx)
  {
    fz_run_display_list(ctx, dl, &d->base, fz_translate(-b.x0, -b.y0), fz_infinite_rect, NULL);
    fz_close_device(ctx, &d->base);
  }
  fz_catch(ctx) ok = false;
  if (ok)
  {
    if (c->dl) fz_drop_display_list(ctx, c->dl);
    free(c->b.p);
    memset(&c->b, 0, sizeof c->b);
    make_tdl(&c->b, page, b, d);
    c->dl = fz_keep_display_list(ctx, dl);
    c->key = fz_hash_display_list(ctx, dl) ^ ((uint64_t)page << 48);
    c->ops = d->nops;
    c->fonts = d->nfonts;
    c->us = now_us() - t0;
  }
  free_tdl_dev(d);
  if (!ok) { *err = "cannot run the page"; return NULL; }
  return c;
}

static bool page_tdl(int page, const unsigned char **bytes, size_t *len, uint64_t *key)
{
  const char *err;
  tdl_cached *c = page_tdl_cached(page, &err);
  if (!c) return false;
  *bytes = c->b.p;
  *len = c->b.n;
  *key = c->key;
  return true;
}

static bool cmd_dlist(vstack *st, val cmd, int n)
{
  if (n != 4) { fprintf(out, "{\"ok\":false,\"error\":\"dlist takes 3 arguments\"}\n"); return true; }
  double id = val_number(ctx, val_array_get(ctx, st, cmd, 1));
  int page = val_number(ctx, val_array_get(ctx, st, cmd, 2));
  const char *path = val_string(ctx, st, val_array_get(ctx, st, cmd, 3));
  int64_t t0 = now_us();
  const char *err;
  tdl_cached *c = page_tdl_cached(page, &err);
  if (!c)
  {
    if (!strcmp(err, "no page")) fprintf(out, "{\"id\":%.0f,\"ok\":false,\"error\":\"no page %d\"}\n", id, page);
    else fprintf(out, "{\"id\":%.0f,\"ok\":false,\"error\":\"%s\"}\n", id, err);
    return true;
  }
  bool ok = false;
  FILE *f = fopen(path, "wb");
  if (f)
  {
    ok = fwrite(c->b.p, 1, c->b.n, f) == c->b.n;
    ok = fclose(f) == 0 && ok;
  }
  if (ok)
    fprintf(out, "{\"id\":%.0f,\"ok\":true,\"bytes\":%zu,\"ops\":%d,\"fonts\":%d,\"us\":%lld}\n", id, c->b.n, c->ops,
            c->fonts, (long long)(now_us() - t0));
  else
    fprintf(out, "{\"id\":%.0f,\"ok\":false,\"error\":\"cannot write\"}\n", id);
  return true;
}
