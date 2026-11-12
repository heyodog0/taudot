// ["glyphs", id, page, out_path]: every glyph of a page, with its box, text, size and the typeset line and word it
// belongs to, written to out_path as JSON.
// Included by txp-render.c: txp-headless's statics (ctx, out, page_dl, ...) are in scope.
//
// Answer: {"id":ID,"ok":true,"n":N,"us":T}  (N glyphs, T µs including typesetting the page if it wasn't cached)
//
// File format (independent of MuPDF: the new backend's display list will serve the same verb):
//   {"page":P,"w":W,"h":H,"fonts":[name,...],
//    "glyphs":[{"t":text,"b":[x0,y0,x1,y1],"i":[x0,y0,x1,y1],"o":[x,y],"s":size,"f":font,"l":line,"w":word,"c":clip},...],
//    "lines":[{"b":[...],"base":y,"g":[first,count]},...],
//    "words":[{"t":text,"b":[...],"l":line,"g":[first,count]},...]}
// Units are PDF points from the page's top-left corner, y down: the same frame as "render" at scale 1.
//   t     the glyph's Unicode text. A ligature carries its letters ("fi", "ffl"), one glyph with a longer text.
//         Unknown glyphs are "�".
//   b     the advance box: from the origin to origin + advance, from the font's descender to its ascender. Boxes of
//         neighbouring glyphs touch, so a caret between two glyphs is at b[2] of the first.
//   i     the ink box (the outline's bounds); empty glyphs (a space in some fonts) have i = b.
//   o     the origin on the baseline. s: the font size in points. f: index into "fonts".
//   c     clip depth when drawn: 0 for running text; > 0 inside clipped content (included figures, mostly).
// Glyphs are in drawing order, which for TeX is reading order within a line. Lines group glyphs that follow each
// other on one baseline (sub- and superscripts stay in their line); words split a line at gaps wider than 0.15 em.

typedef struct
{
  char t[32];
  fz_rect b, i;
  fz_point o;
  float s;
  int f, line, word, clip;
} glyph_rec;

typedef struct
{
  fz_device base;
  glyph_rec *g;
  int n, cap;
  fz_font *fonts[256];
  int nfonts;
  int clip;
  // ink bounds per (font, glyph) in glyph space, an open-addressed table: a page has ~100 distinct glyphs
  struct { fz_font *font; int gid; fz_rect r; } ink[4096];
} glyph_dev;

static fz_rect glyph_ink(fz_context *ctx, glyph_dev *d, fz_font *font, int gid)
{
  unsigned h = ((unsigned)(uintptr_t)font * 2654435761u ^ (unsigned)gid * 40503u) & 4095;
  for (int probe = 0; probe < 4096; probe++, h = (h + 1) & 4095)
  {
    if (d->ink[h].font == font && d->ink[h].gid == gid) return d->ink[h].r;
    if (d->ink[h].font) continue;
    fz_rect r = fz_empty_rect;
    fz_path *path = fz_outline_glyph(ctx, font, gid, fz_identity);
    if (path)
    {
      r = fz_bound_path(ctx, path, NULL, fz_identity);
      fz_drop_path(ctx, path);
    }
    d->ink[h].font = font;
    d->ink[h].gid = gid;
    d->ink[h].r = r;
    return r;
  }
  return fz_empty_rect;
}

static int utf8_put(char *s, int c)
{
  if (c < 0x80) { s[0] = c; return 1; }
  if (c < 0x800) { s[0] = 0xc0 | (c >> 6); s[1] = 0x80 | (c & 0x3f); return 2; }
  if (c < 0x10000) { s[0] = 0xe0 | (c >> 12); s[1] = 0x80 | ((c >> 6) & 0x3f); s[2] = 0x80 | (c & 0x3f); return 3; }
  s[0] = 0xf0 | (c >> 18); s[1] = 0x80 | ((c >> 12) & 0x3f); s[2] = 0x80 | ((c >> 6) & 0x3f); s[3] = 0x80 | (c & 0x3f);
  return 4;
}

// One code point → letters: Unicode's Latin ligatures come apart.
static int put_letters(char *s, int c)
{
  static const char *lig[] = {"ff", "fi", "fl", "ffi", "ffl", "st", "st"};
  if (c >= 0xfb00 && c <= 0xfb06) { strcpy(s, lig[c - 0xfb00]); return strlen(lig[c - 0xfb00]); }
  if (c == 0x132) { strcpy(s, "IJ"); return 2; }
  if (c == 0x133) { strcpy(s, "ij"); return 2; }
  return utf8_put(s, c);
}

// A glyph name → text: "fi" → "fi", "f_f_i" → "ffi", "a.sc" → "a", "uni00E9" → "é". 0 when unknown.
static int text_from_name(const char *name, char *t)
{
  char base[64];
  int k = 0;
  for (; name[k] && name[k] != '.' && k < 63; k++) base[k] = name[k];
  base[k] = 0;
  if (!base[0]) return 0;
  int c = fz_unicode_from_glyph_name(base);
  if (c > 0) return put_letters(t, c);
  // components joined by '_' (OpenType ligature names)
  if (strchr(base, '_'))
  {
    int n = 0;
    char *save = NULL;
    for (char *p = strtok_r(base, "_", &save); p; p = strtok_r(NULL, "_", &save))
    {
      int u = fz_unicode_from_glyph_name(p);
      if (u <= 0 || n > 20) return 0;
      n += put_letters(t + n, u);
    }
    return n;
  }
  return 0;
}

static void glyph_text(fz_context *ctx, fz_font *font, const fz_text_item *it, char *t)
{
  char name[64] = "";
  int n = 0;
  if (it->gid >= 0)
  {
    fz_get_glyph_name(ctx, font, it->gid, name, sizeof name);
    n = text_from_name(name, t);
  }
  // TeXpresso passes the TeX character code for TFM fonts and 0 for XeTeX's native fonts: only plain ASCII is
  // trustworthy (OT1 puts ligatures and accents below 0x20 and quotes at 0x27/0x60)
  if (!n && it->ucs > 0x20 && it->ucs < 0x7f && it->ucs != 0x27 && it->ucs != 0x60) n = utf8_put(t, it->ucs);
  if (!n) n = utf8_put(t, 0xfffd);
  t[n] = 0;
}

static int font_index(glyph_dev *d, fz_font *font)
{
  for (int i = 0; i < d->nfonts; i++)
    if (d->fonts[i] == font) return i;
  if (d->nfonts == 256) return 255;
  d->fonts[d->nfonts] = font;
  return d->nfonts++;
}

static void glyphs_text(fz_context *ctx, fz_device *dev, const fz_text *text, fz_matrix ctm)
{
  glyph_dev *d = (glyph_dev *)dev;
  for (fz_text_span *sp = text->head; sp; sp = sp->next)
  {
    float asc = fz_font_ascender(ctx, sp->font), desc = fz_font_descender(ctx, sp->font);
    // fonts with a giant bbox (maths extension fonts): keep the caret box to a line's height
    if (asc > 1.0f || asc < 0.5f) asc = 0.75f;
    if (desc < -0.35f || desc > 0) desc = -0.25f;
    int fi = font_index(d, sp->font);
    for (int k = 0; k < sp->len; k++)
    {
      const fz_text_item *it = &sp->items[k];
      if (it->gid < 0) continue;  // the rest of a one-glyph-many-letters mapping: the glyph already carries them
      if (d->n == d->cap)
      {
        d->cap = d->cap ? d->cap * 2 : 4096;
        d->g = fz_realloc(ctx, d->g, d->cap * sizeof *d->g);
      }
      glyph_rec *g = &d->g[d->n];
      fz_matrix trm = sp->trm;
      trm.e = it->x;
      trm.f = it->y;
      fz_matrix m = fz_concat(trm, ctm);
      float adv = fz_advance_glyph(ctx, sp->font, it->gid, sp->wmode);
      fz_rect r = fz_make_rect(0, desc, adv, asc);
      g->b = fz_transform_rect(r, m);
      // ink: the outline's bounds (fz_bound_glyph gives the font's bbox for Type 1 fonts)
      fz_rect ink = glyph_ink(ctx, d, sp->font, it->gid);
      g->i = fz_is_empty_rect(ink) || fz_is_infinite_rect(ink) ? g->b : fz_transform_rect(ink, m);
      g->o = fz_make_point(m.e, m.f);
      g->s = sqrtf(fabsf(m.a * m.d - m.b * m.c));
      g->f = fi;
      g->clip = d->clip;
      glyph_text(ctx, sp->font, it, g->t);
      d->n++;
    }
  }
}

static void glyphs_fill_text(fz_context *ctx, fz_device *dev, const fz_text *text, fz_matrix ctm, fz_colorspace *cs,
                             const float *color, float alpha, fz_color_params cp)
{
  (void)cs; (void)color; (void)alpha; (void)cp;
  glyphs_text(ctx, dev, text, ctm);
}

static void glyphs_stroke_text(fz_context *ctx, fz_device *dev, const fz_text *text, const fz_stroke_state *ss,
                               fz_matrix ctm, fz_colorspace *cs, const float *color, float alpha, fz_color_params cp)
{
  (void)ss; (void)cs; (void)color; (void)alpha; (void)cp;
  glyphs_text(ctx, dev, text, ctm);
}

static void glyphs_clip_path(fz_context *c, fz_device *dev, const fz_path *p, int eo, fz_matrix m, fz_rect s)
{ (void)c; (void)p; (void)eo; (void)m; (void)s; ((glyph_dev *)dev)->clip++; }
static void glyphs_clip_stroke_path(fz_context *c, fz_device *dev, const fz_path *p, const fz_stroke_state *ss,
                                    fz_matrix m, fz_rect s)
{ (void)c; (void)p; (void)ss; (void)m; (void)s; ((glyph_dev *)dev)->clip++; }
static void glyphs_clip_text(fz_context *c, fz_device *dev, const fz_text *t, fz_matrix m, fz_rect s)
{ (void)c; (void)t; (void)m; (void)s; ((glyph_dev *)dev)->clip++; }
static void glyphs_clip_stroke_text(fz_context *c, fz_device *dev, const fz_text *t, const fz_stroke_state *ss,
                                    fz_matrix m, fz_rect s)
{ (void)c; (void)t; (void)ss; (void)m; (void)s; ((glyph_dev *)dev)->clip++; }
static void glyphs_clip_image_mask(fz_context *c, fz_device *dev, fz_image *im, fz_matrix m, fz_rect s)
{ (void)c; (void)im; (void)m; (void)s; ((glyph_dev *)dev)->clip++; }
// An included PDF page: its characters from PDFKit (swift/Sources/TaudotRenderC/FigureText.swift), in the frame the
// rest of the page uses. Fonts are stand-ins carrying the figure's font names.
int taudot_figure_chars(const char *path, int page, float **boxes, char **text);

static fz_font *figure_font(const char *name)
{
  static fz_font *fonts[256];
  static int n;
  for (int i = 0; i < n; i++)
    if (!strncmp(fonts[i]->name, name, sizeof fonts[i]->name - 1)) return fonts[i];
  if (n == 256) return fonts[255];
  fz_font *f = calloc(1, sizeof *f);
  f->refs = 1 << 30;
  snprintf(f->name, sizeof f->name, "%s", name);
  return fonts[n++] = f;
}

static void glyphs_fill_figure(fz_context *c, fz_device *dev, fz_figure *fig, fz_matrix m)
{
  glyph_dev *d = (glyph_dev *)dev;
  float *boxes = NULL;
  char *text = NULL;
  int n = taudot_figure_chars(fig->path, fig->page, &boxes, &text);
  const char *t = text;
  for (int k = 0; k < n; k++)
  {
    const char *font = t + strlen(t) + 1;
    if (d->n == d->cap)
    {
      d->cap = d->cap ? d->cap * 2 : 4096;
      d->g = fz_realloc(c, d->g, d->cap * sizeof *d->g);
    }
    glyph_rec *g = &d->g[d->n++];
    fz_rect r = fz_transform_rect(fz_make_rect(boxes[4 * k], boxes[4 * k + 1], boxes[4 * k + 2], boxes[4 * k + 3]), m);
    g->b = g->i = r;
    float h = r.y1 - r.y0;
    g->o = fz_make_point(r.x0, r.y1 - 0.2f * h);  // PDFKit gives no baseline: a fifth of the box above its bottom
    g->s = h;
    g->f = font_index(d, figure_font(font));
    g->clip = d->clip;
    snprintf(g->t, sizeof g->t, "%s", t);
    t = font + strlen(font) + 1;
  }
  free(boxes);
  free(text);
}

static void glyphs_pop_clip(fz_context *c, fz_device *dev)
{ (void)c; glyph_dev *d = (glyph_dev *)dev; if (d->clip > 0) d->clip--; }

static void json_rect(FILE *f, fz_rect r)
{
  fprintf(f, "[%.2f,%.2f,%.2f,%.2f]", r.x0, r.y0, r.x1, r.y1);
}

// Lines and words, in drawing order. A glyph continues the line when its baseline is within 0.6 em of the line's
// and it doesn't step back more than 0.6 em (an OT1 accent is drawn before its letter and kerned back over it).
static void group_glyphs(glyph_rec *g, int n)
{
  int line = -1, word = -1;
  float base = 0, right = 0, em = 0;
  for (int i = 0; i < n; i++)
  {
    float s = g[i].s > 0 ? g[i].s : 10;
    bool same_line = line >= 0 && g[i].clip == g[i - 1].clip && fabsf(g[i].o.y - base) < 0.6f * fmaxf(em, s) &&
                     g[i].b.x0 > right - 0.6f * fmaxf(em, s);
    if (!same_line)
    {
      line++;
      word++;
      base = g[i].o.y;
      em = s;
    }
    else if (g[i].b.x0 - right > 0.15f * fmaxf(fminf(em, s), 1))
      word++;
    // the line's baseline is its main text's: a smaller glyph (a superscript) doesn't move it
    if (s > em * 1.05f) { base = g[i].o.y; em = s; }
    g[i].line = line;
    g[i].word = word;
    if (!same_line || g[i].b.x1 > right) right = g[i].b.x1;
  }
}

static void write_glyphs(FILE *f, int page, fz_rect bounds, glyph_dev *d)
{
  glyph_rec *g = d->g;
  int n = d->n;
  fprintf(f, "{\"page\":%d,\"w\":%.3f,\"h\":%.3f,\"fonts\":[", page, bounds.x1 - bounds.x0, bounds.y1 - bounds.y0);
  for (int i = 0; i < d->nfonts; i++)
  {
    const char *name = fz_font_name(ctx, d->fonts[i]);
    if (i) fputc(',', f);
    json_str(f, name, strlen(name));
  }
  fprintf(f, "],\n\"glyphs\":[");
  for (int i = 0; i < n; i++)
  {
    fprintf(f, "%s\n{\"t\":", i ? "," : "");
    json_str(f, g[i].t, strlen(g[i].t));
    fprintf(f, ",\"b\":");
    json_rect(f, g[i].b);
    fprintf(f, ",\"i\":");
    json_rect(f, g[i].i);
    fprintf(f, ",\"o\":[%.2f,%.2f],\"s\":%.2f,\"f\":%d,\"l\":%d,\"w\":%d,\"c\":%d}", g[i].o.x, g[i].o.y, g[i].s, g[i].f,
            g[i].line, g[i].word, g[i].clip);
  }
  fprintf(f, "],\n\"lines\":[");
  for (int i = 0, k = 0; i < n; k++)
  {
    int j = i;
    fz_rect r = fz_empty_rect;
    while (j < n && g[j].line == g[i].line) r = fz_union_rect(r, g[j++].b);
    fprintf(f, "%s\n{\"b\":", k ? "," : "");
    json_rect(f, r);
    // the baseline of the line's largest glyph
    int big = i;
    for (int m = i; m < j; m++) if (g[m].s > g[big].s) big = m;
    fprintf(f, ",\"base\":%.2f,\"g\":[%d,%d]}", g[big].o.y, i, j - i);
    i = j;
  }
  fprintf(f, "],\n\"words\":[");
  char buf[4096];
  for (int i = 0, k = 0; i < n; k++)
  {
    int j = i, len = 0;
    fz_rect r = fz_empty_rect;
    while (j < n && g[j].word == g[i].word)
    {
      int tl = strlen(g[j].t);
      if (len + tl < (int)sizeof buf) { memcpy(buf + len, g[j].t, tl); len += tl; }
      r = fz_union_rect(r, g[j++].b);
    }
    fprintf(f, "%s\n{\"t\":", k ? "," : "");
    json_str(f, buf, len);
    fprintf(f, ",\"b\":");
    json_rect(f, r);
    fprintf(f, ",\"l\":%d,\"g\":[%d,%d]}", g[i].line, i, j - i);
    i = j;
  }
  fprintf(f, "]}\n");
}

static bool cmd_glyphs(vstack *st, val cmd, int n)
{
  if (n != 4) { fprintf(out, "{\"ok\":false,\"error\":\"glyphs takes 3 arguments\"}\n"); return true; }
  double id = val_number(ctx, val_array_get(ctx, st, cmd, 1));
  int page = val_number(ctx, val_array_get(ctx, st, cmd, 2));
  const char *path = val_string(ctx, st, val_array_get(ctx, st, cmd, 3));
  int64_t t0 = now_us();
  fz_display_list *dl = page_dl(page);
  if (!dl)
  {
    fprintf(out, "{\"id\":%.0f,\"ok\":false,\"error\":\"no page %d\"}\n", id, page);
    return true;
  }
  fz_rect b = fz_bound_display_list(ctx, dl);
  glyph_dev *d = fz_new_derived_device(ctx, glyph_dev);
  d->base.fill_text = glyphs_fill_text;
  d->base.stroke_text = glyphs_stroke_text;
  d->base.clip_path = glyphs_clip_path;
  d->base.clip_stroke_path = glyphs_clip_stroke_path;
  d->base.clip_text = glyphs_clip_text;
  d->base.clip_stroke_text = glyphs_clip_stroke_text;
  d->base.clip_image_mask = glyphs_clip_image_mask;
  d->base.pop_clip = glyphs_pop_clip;
  d->base.fill_figure = glyphs_fill_figure;
  bool ok = true;
  fz_try(ctx)
  {
    fz_run_display_list(ctx, dl, &d->base, fz_translate(-b.x0, -b.y0), fz_infinite_rect, NULL);
    fz_close_device(ctx, &d->base);
  }
  fz_catch(ctx) ok = false;
  int count = d->n;
  if (ok)
  {
    group_glyphs(d->g, d->n);
    FILE *f = fopen(path, "wb");
    if (f)
    {
      write_glyphs(f, page, b, d);
      ok = fclose(f) == 0;
    }
    else
      ok = false;
  }
  fz_free(ctx, d->g);
  fz_drop_device(ctx, &d->base);
  if (ok)
    fprintf(out, "{\"id\":%.0f,\"ok\":true,\"n\":%d,\"us\":%lld}\n", id, count, (long long)(now_us() - t0));
  else
    fprintf(out, "{\"id\":%.0f,\"ok\":false,\"error\":\"cannot write\"}\n", id);
  return true;
}
