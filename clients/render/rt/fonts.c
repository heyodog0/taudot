/* Taudot's drawing runtime: fonts, through the FreeType loader in ../fonts (taudot_font.h).
 * Copyright (c) 2026 the Taudot authors. MIT License (rt/LICENSE). */

#include "mupdf/fitz.h"
#include "../fonts/taudot_font.h"

static void load_lists(void);

/* advances are asked for every glyph drawn: cached per font */
typedef struct { int gid; float adv; } adv_slot;
typedef struct
{
  fz_font font;
  adv_slot *adv;
  int adv_cap, adv_n;
} rt_font;

fz_font *fz_new_font_from_buffer(fz_context *ctx, const char *name, fz_buffer *buffer, int index, int use_glyph_bbox)
{
  (void)name; (void)use_glyph_bbox;
  tf_font *tf = tf_font_new(buffer->data, buffer->len, index);
  if (!tf) fz_throw(ctx, FZ_ERROR_FORMAT, "cannot load font (face %d)", index);
  rt_font *r = fz_malloc_struct(ctx, rt_font);
  fz_font *f = &r->font;
  f->refs = 1;
  f->tf = tf;
  f->buffer = fz_keep_buffer(ctx, buffer);
  f->index = index;
  snprintf(f->name, sizeof f->name, "%s", tf_font_name(tf));
  return f;
}

fz_font *fz_keep_font(fz_context *ctx, fz_font *f) { (void)ctx; if (f) f->refs++; return f; }

void fz_drop_font(fz_context *ctx, fz_font *f)
{
  if (!f || --f->refs > 0) return;
  tf_font_drop(f->tf);
  fz_drop_buffer(ctx, f->buffer);
  free(((rt_font *)f)->adv);
  free(f);
}

const char *fz_font_name(fz_context *ctx, fz_font *f) { (void)ctx; return f ? f->name : ""; }
float fz_font_ascender(fz_context *ctx, fz_font *f) { (void)ctx; return f ? tf_font_ascender(f->tf) : 0.8f; }
float fz_font_descender(fz_context *ctx, fz_font *f) { (void)ctx; return f ? tf_font_descender(f->tf) : -0.2f; }
int fz_encode_character(fz_context *ctx, fz_font *f, int u) { (void)ctx; return tf_encode_char(f->tf, u); }
int fz_encode_character_by_glyph_name(fz_context *ctx, fz_font *f, const char *name)
{
  (void)ctx;
  load_lists();
  return tf_encode_glyph_name(f->tf, name);
}

float fz_advance_glyph(fz_context *ctx, fz_font *f, int gid, int wmode)
{
  (void)ctx;
  if (wmode || gid < 0) return tf_glyph_advance(f->tf, gid, wmode);
  rt_font *r = (rt_font *)f;
  if (r->adv_n * 2 >= r->adv_cap)
  {
    int cap = r->adv_cap ? r->adv_cap * 2 : 512;
    adv_slot *t = malloc(sizeof(adv_slot) * cap);
    for (int i = 0; i < cap; i++) t[i].gid = -1;
    for (int i = 0; i < r->adv_cap; i++)
      if (r->adv[i].gid >= 0)
      {
        unsigned h = (unsigned)r->adv[i].gid * 2654435761u & (cap - 1);
        while (t[h].gid >= 0) h = (h + 1) & (cap - 1);
        t[h] = r->adv[i];
      }
    free(r->adv);
    r->adv = t;
    r->adv_cap = cap;
  }
  unsigned h = (unsigned)gid * 2654435761u & (r->adv_cap - 1);
  while (r->adv[h].gid >= 0)
  {
    if (r->adv[h].gid == gid) return r->adv[h].adv;
    h = (h + 1) & (r->adv_cap - 1);
  }
  r->adv[h].gid = gid;
  r->adv[h].adv = tf_glyph_advance(f->tf, gid, 0);
  r->adv_n++;
  return r->adv[h].adv;
}

fz_path *fz_outline_glyph(fz_context *ctx, fz_font *f, int gid, fz_matrix ctm)
{
  tf_path p;
  if (gid < 0 || tf_glyph_outline(f->tf, gid, &p) != 0) return NULL;
  if (p.ncmd == 0) { tf_path_free(&p); return NULL; }
  fz_path *path = fz_new_path(ctx);
  const float *v = p.coord;
  for (uint32_t i = 0; i < p.ncmd; i++)
  {
    fz_point a, b, c;
    switch (p.cmd[i])
    {
      case 'M': a = fz_transform_point_xy(v[0], v[1], ctm); fz_moveto(ctx, path, a.x, a.y); v += 2; break;
      case 'L': a = fz_transform_point_xy(v[0], v[1], ctm); fz_lineto(ctx, path, a.x, a.y); v += 2; break;
      case 'Q':
        a = fz_transform_point_xy(v[0], v[1], ctm); b = fz_transform_point_xy(v[2], v[3], ctm);
        fz_quadto(ctx, path, a.x, a.y, b.x, b.y);
        v += 4;
        break;
      case 'C':
        a = fz_transform_point_xy(v[0], v[1], ctm); b = fz_transform_point_xy(v[2], v[3], ctm);
        c = fz_transform_point_xy(v[4], v[5], ctm);
        fz_curveto(ctx, path, a.x, a.y, b.x, b.y, c.x, c.y);
        v += 6;
        break;
      case 'Z': fz_closepath(ctx, path); break;
    }
  }
  tf_path_free(&p);
  return path;
}

void fz_get_glyph_name(fz_context *ctx, fz_font *f, int gid, char *buf, int size)
{
  (void)ctx;
  if (tf_glyph_name(f->tf, gid, buf, size) != 0 && size > 0) buf[0] = 0;
}

/* The lists come from the TeX bundle on first use (rt_glyph_list_path, set by the driver). */
const char *(*rt_glyph_list_path)(const char *name);
static int lists_loaded;

static char *slurp(const char *path, size_t *len)
{
  *len = 0;
  if (!path) return NULL;
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *b = malloc(n > 0 ? n : 1);
  *len = n > 0 ? fread(b, 1, n, f) : 0;
  fclose(f);
  return b;
}

void fz_set_glyph_lists(const char *agl, size_t agl_len, const char *tex, size_t tex_len)
{
  tf_glyph_lists(agl, agl_len, tex, tex_len);
  lists_loaded = 1;
}

static void load_lists(void)
{
  if (!lists_loaded && rt_glyph_list_path)
  {
    size_t al, tl;
    char *a = slurp(rt_glyph_list_path("glyphlist.txt"), &al);
    char *t = slurp(rt_glyph_list_path("texglyphlist.txt"), &tl);
    if (!a) fprintf(stderr, "taudot-rt: no glyphlist.txt in the bundle: glyph names won't give text\n");
    fz_set_glyph_lists(a, al, t, tl);
    free(a);
    free(t);
  }
}

int fz_unicode_from_glyph_name(const char *name)
{
  load_lists();
  int u = tf_unicode_from_glyph_name(name);
  return u == 0xfffd ? 0 : u;
}
