/*
 * MIT License
 *
 * Copyright (c) 2023 Frédéric Bour <frederic.bour@lakaban.net>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to
 * deal in the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
 * sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */

#include <mupdf/pdf.h>
#include <string.h>
#include "fz_util.h"
#include "mydvi.h"
#include "mydvi_interp.h"
#include "pdf_lexer.h"
#include "vstack.h"
#include <math.h>

#define device_cs fz_device_rgb
#define color_params fz_default_color_params

typedef const char *cursor_t;

/*!re2c

re2c:yyfill:enable = 0;
re2c:eof = -1;
re2c:flags:input = custom;
re2c:api:style = free-form;
re2c:define:YYCURSOR    = cur;
re2c:define:YYCTYPE     = int;
re2c:define:YYLESSTHAN  = "cur >= lim";
re2c:define:YYPEEK      = "cur < lim ? *cur : -1";
re2c:define:YYSKIP      = "++cur;";
re2c:define:YYBACKUP    = "mar = cur;";
re2c:define:YYRESTORE   = "cur = mar;";
re2c:define:YYSTAGP     = "@@{tag} = cur;";
re2c:define:YYSTAGN     = "@@{tag} = NULL;";
re2c:define:YYSHIFT     = "cur += @@{shift};";
re2c:define:YYSHIFTSTAG = "@@{tag} += @@{shift};";

nat     = [0-9]+;
int     = "-"? nat;
float   = int ("." nat*)?;
ws      = " ";
rawunit = ("pt" | "mm" | "cm" | "in");
unit    = "true"? rawunit;
dim     = float unit;

*/

/*!stags:re2c format = 'static cursor_t @@;\n'; */

static bool
unhandled(const char *kind, cursor_t cur, cursor_t lim, int ignored)
{
  if (0 && !ignored)
    fprintf(stderr, "unhandled %s: \"%.*s\"\n", kind, (int)(lim - cur), cur);
  return 0;
}

static int pnat(cursor_t ptr, cursor_t lim)
{
  int result = 0;
  for (; ptr < lim && *ptr >= '0' && *ptr <= '9'; ptr += 1)
    result = result * 10 + (*ptr - '0');
  return result;
}

static int pint(cursor_t ptr, cursor_t lim)
{
  if (ptr < lim && *ptr == '-')
    return -pnat(ptr + 1, lim);
  else
    return pnat(ptr, lim);
}

static float
punit(cursor_t cur, cursor_t lim)
{
  if (cur + 2 >= lim)
    return 1.0;

  if (cur + 6 >= lim &&
      cur[0] == 't' && cur[1] == 'r' &&
      cur[2] == 'u' && cur[3] == 'e')
  {
    // TODO: "true" units are not yet supported
    cur += 4;
  }

  char c0 = cur[0];
  char c1 = cur[1];

  if (0);
  else if (c0 == 'p' && c1 == 't')
    return 1.0;
  else if (c0 == 'm' && c1 == 'm')
    return 2.845274;
  else if (c0 == 'c' && c1 == 'm')
    return 28.45274;
  else if (c0 == 'i' && c1 == 'n')
    return 72.27;

  return 1.0;
}

static float
pfloat_or_dim(cursor_t ptr, cursor_t lim, bool is_dim)
{
  int neg = 0;
  double result = 0;
  if (ptr < lim && *ptr == '-')
  {
    neg = 1;
    ptr += 1;
  }
  for (; ptr < lim && *ptr >= '0' && *ptr <= '9'; ptr += 1)
    result = result * 10 + (*ptr - '0');
  if (ptr < lim  && *ptr == '.')
  {
    ptr += 1;
    double pos = 0.1;
    for (; ptr < lim && *ptr >= '0' && *ptr <= '9'; ptr += 1)
    {
      result += pos * (*ptr - '0');
      pos /= 10;
    }
  }

  if (is_dim)
    result *= punit(ptr, lim) * 800/803;
  return neg ? -result : result;
}

static float pfloat(cursor_t ptr, cursor_t lim)
{
  return pfloat_or_dim(ptr, lim, 0);
}

static float pdim(cursor_t ptr, cursor_t lim)
{
  return pfloat_or_dim(ptr, lim, 1);
}

static void color_set_rgb(float color[3], float r, float g, float b)
{
  color[0] = r;
  color[1] = g;
  color[2] = b;
}

static void color_set_gray(float color[3], float gray)
{
  color_set_rgb(color, gray, gray, gray);
}

/* Taudot (MIT): CMYK through MuPDF's colour management (its default CMYK profile), as a PDF viewer does, not the
   naive 1 - c - k formula: xcolor's yellow (0 0 1 0) is 255 241 0 in mutool, not 255 255 0. */
static void color_set_cmyk(fz_context *ctx, float color[3], float c, float m, float y, float k)
{
  float cmyk[4] = {c, m, y, k};
  fz_convert_color(ctx, fz_device_cmyk(ctx), cmyk, fz_device_rgb(ctx), color, NULL, fz_default_color_params);
}

static bool
color_parse_rgb(float color[3], cursor_t r, cursor_t g, cursor_t b, cursor_t lim)
{
  color_set_rgb(color, pfloat(r, lim), pfloat(g, lim), pfloat(b, lim));
  return 1;
}

static bool
color_parse_gray(float color[3], cursor_t gray, cursor_t lim)
{
  color_set_gray(color, pfloat(gray, lim));
  return 1;
}

static bool
color_parse_cmyk(fz_context *ctx, float color[3], cursor_t c, cursor_t m, cursor_t y, cursor_t k, cursor_t lim)
{
  color_set_cmyk(ctx, color, pfloat(c, lim), pfloat(m, lim),
                        pfloat(y, lim), pfloat(k, lim));
  return 1;
}

static bool parse_color(fz_context *ctx, dvi_colorstate *state, cursor_t cur, cursor_t lim)
{
  cursor_t mar, f0, f1, f2, f3;
  // fprintf(stderr, "parse_color: %.*s\n", (int)(lim - cur), cur);
  float color[3];

  do
  {
    /*!re2c

    " "
    { continue; }

    "gray" ws+ @f0 float
    {
      color_parse_gray(color, f0, lim);
      break;
    }

    "rgb" ws+ @f0 float
          ws+ @f1 float
          ws+ @f2 float
    {
      color_parse_rgb(color, f0, f1, f2, lim);
      break;
    }

    "cmyk" ws+ @f0 float
           ws+ @f1 float
           ws+ @f2 float
           ws+ @f3 float
    {
      color_parse_cmyk(ctx, color, f0, f1, f2, f3, lim);
      break;
    }

    ''
    { return unhandled("color", cur, lim, 0); }

    */
  }
  while (0);

  state->fill[0] = state->line[0] = color[0];
  state->fill[1] = state->line[1] = color[1];
  state->fill[2] = state->line[2] = color[2];
  return 1;
}

static bool parse_pdfcolor(fz_context *ctx, dvi_colorstate *state, cursor_t cur, cursor_t lim)
{
  cursor_t mar, f0, f1, f2, f3;

  for (;;)
  {
    /*!re2c

    ")"
    { return 1; }

    " "
    { continue; }

    @f0 float ws+
    @f1 float ws+
    @f2 float ws+
    @f3 float ws+
    "k"
    { return color_parse_cmyk(ctx, state->fill, f0, f1, f2, f3, lim); }

    @f0 float ws+
    @f1 float ws+
    @f2 float ws+
    @f3 float ws+
    "K"
    { return color_parse_cmyk(ctx, state->line, f0, f1, f2, f3, lim); }

    @f0 float ws+
    "g"
    { return color_parse_gray(state->fill, f0, lim); }

    @f0 float ws+
    "G"
    { return color_parse_gray(state->line, f0, lim); }

    @f0 float ws+
    @f1 float ws+
    @f2 float ws+
    "rg"
    { return color_parse_rgb(state->fill, f0, f1, f2, lim); }

    @f0 float ws+
    @f1 float ws+
    @f2 float ws+
    "RG"
    { return color_parse_rgb(state->line, f0, f1, f2, lim); }

    ''
    { return unhandled("pdf color", cur, lim, 0); }

    */
  }
}

static bool
pdfcolorstack_current(fz_context *ctx, dvi_context *dc, dvi_state *st, int index)
{
  dvi_context_flush_text(ctx, dc, st);
  if (index >= dc->pdfcolorstacks.capacity)
  {
    fprintf(stderr, "pdfcolorstack_current %d: no such stack\n", index);
    return 0;
  }
  //printf("pdfcolorstack_current %d\n", index);
  dvi_colorstack *stack = index == -1 ? &dc->colorstack : &dc->pdfcolorstacks.stacks[index];
  if (stack->depth == 0)
    st->gs.colors = stack->origin;
  else
    st->gs.colors = stack->base[stack->depth - 1];
  return 1;
}

static bool
colorstack_push(fz_context *ctx, dvi_context *dc, dvi_state *st, int index)
{
  dvi_context_flush_text(ctx, dc, st);
  if (index >= dc->pdfcolorstacks.capacity)
  {
    fprintf(stderr, "pdfcolorstack_push %d: no such stack\n", index);
    return 0;
  }
  //printf("pdfcolorstack_push %d\n", index);
  dvi_colorstack *stack = index == -1 ? &dc->colorstack : &dc->pdfcolorstacks.stacks[index];

  //fprintf(stderr, "pdfcolorstack_push: depth=%d, limit=%d\n", stack->depth, stack->limit);
  if (stack->depth == stack->limit)
  {
    size_t size = stack->limit;
    size = size == 0 ? 16 : size * 2;
    dvi_colorstate *base = fz_malloc_struct_array(ctx, size, dvi_colorstate);
    if (!base) abort();
    if (stack->limit > 0)
    {
      memcpy(base, stack->base, sizeof(dvi_colorstate) * stack->limit);
      fz_free(ctx, stack->base);
    }
    stack->base = base;
    stack->limit = size;
  }

  stack->base[stack->depth] = st->gs.colors;
  stack->depth += 1;

  return 1;
}

static bool
colorstack_pop(fz_context *ctx, dvi_context *dc, dvi_state *st, int index)
{
  dvi_context_flush_text(ctx, dc, st);
  if (index >= dc->pdfcolorstacks.capacity)
  {
    fprintf(stderr, "pdfcolorstack_pop %d: no such stack\n", index);
    return 0;
  }
  dvi_colorstack *stack = index == -1 ? &dc->colorstack : &dc->pdfcolorstacks.stacks[index];
  if (stack->depth == 0)
  {
    fprintf(stderr, "pdfcolorstack_pop %d: empty stack\n", index);
    return 0;
  }
  stack->depth -= 1;
  st->gs.colors = stack->base[stack->depth];
  return 1;
}

static bool
colorstack_init(fz_context *ctx, dvi_context *dc, dvi_state *st, int index)
{
  if (index >= dc->pdfcolorstacks.capacity)
  {
    size_t cap = dc->pdfcolorstacks.capacity;
    size_t newcap = cap == 0 ? 4 : cap;
    while (newcap < index) newcap *= 2;
    dvi_colorstack *stacks = fz_malloc_struct_array(ctx, newcap, dvi_colorstack);
    if (!stacks) abort();
    if (cap > 0)
    {
      memcpy(stacks, dc->pdfcolorstacks.stacks, sizeof(dvi_colorstack) * cap);
      fz_free(ctx, dc->pdfcolorstacks.stacks);
    }
    dc->pdfcolorstacks.stacks = stacks;
    dc->pdfcolorstacks.capacity = newcap;
  }
  //printf("pdfcolorstackinit %d\n", index);
  dvi_colorstack *stack = &dc->pdfcolorstacks.stacks[index];
  return 1;
}

enum pagebox
{
  BOX_UNDEFINED,
  BOX_MEDIABOX,
  BOX_CROPBOX,
  BOX_ARTBOX,
  BOX_BLEEDBOX,
  BOX_TRIMBOX,
};

struct xform_spec
{
  fz_matrix ctm;
  float width, height, depth;
  fz_rect bbox;
  int page, clip;
  enum pagebox pagebox;
};

static struct xform_spec xform_spec()
{
  return (struct xform_spec){
      .ctm = fz_identity,
      .width = NAN,
      .height = NAN,
      .depth = NAN,
      .bbox = fz_infinite_rect,
      .page = -1,
      .clip = 0,
      .pagebox = BOX_UNDEFINED,
  };
}

static bool
embed_pdf(fz_context *ctx, dvi_context *dc, dvi_state *st, struct xform_spec *xf, const char *filename)
{
  /* Taudot (MIT): an included PDF page is one figure op, drawn by Core Graphics (rt/apple.c, swift/), where this
     used to run the page through MuPDF's PDF interpreter. The matrix is the one that interpreter got: the page's
     own (y down, the box's corner at 0) then the CTM, moved up by the box's height. */
  pdf_document *doc = NULL;
  fz_var(doc);
  fz_try(ctx)
    doc = dvi_resmanager_get_pdf(ctx, dc->resmanager, filename);
  fz_catch(ctx)
    return 0;
  if (!doc)
    return 0;
  fz_figure *fig = fz_new_figure(ctx, doc->path, xf->page ? xf->page : 1);
  if (!fig)
    return 0;
  fz_matrix ctm = fz_flip_vertically(dvi_get_ctm(dc, st));
  ctm = fz_concat(xf->ctm, ctm);
  ctm = fz_pre_translate(ctm, 0, fig->box.y0 - fig->box.y1);
  fz_fill_figure(ctx, dc->dev, fig, fz_concat(fz_figure_page_ctm(fig), ctm));
  fz_drop_figure(ctx, fig);
  return 1;
}

static bool
embed_image(fz_context *ctx, dvi_context *dc, dvi_state *st, struct xform_spec *xf, const char *filename)
{

  fz_image *img = NULL;
  fz_var(img);

  fz_try(ctx)
  {
    fz_image *img = dvi_resmanager_get_img(ctx, dc->resmanager, filename);
    fz_matrix ctm = fz_concat(xf->ctm, dvi_get_ctm(dc, st));
    // int xres, yres;
    // fz_image_resolution(img, &xres, &yres);
    // fprintf(stderr, "RENDERING IMAGE, size: %d %d, res: %d %d\n",
    //         img->w, img->h, xres, yres);
    //
    float ar = (float)img->w / (float)img->h;
    float w = xf->width, h = xf->height;
    if (w != w && h != h)
    {
      w = img->w;
      h = img->h;
    }
    else if (w != w)
      w = h * ar;
    else if (h != h)
      h = w / ar;
    ctm = fz_pre_scale(fz_pre_translate(ctm, 0, h), w, -h);
    fz_fill_image(ctx, dc->dev, img, ctm, DVI_FILL_ALPHA(st), color_params);
  }
  fz_always(ctx)
  {
    if (img)
      fz_drop_image(ctx, img);
  }
  fz_catch(ctx)
  {
    return 0;
  }
  return 1;
}

static bool
embed_graphics(fz_context *ctx, dvi_context *dc, dvi_state *st, struct xform_spec *xf, const char *filename)
{
  if (!dc->dev)
    return 1;

  const char *ext = filename;

  for (const char *ptr = ext; *ptr; ptr++)
    if (*ptr == '.') ext = ptr + 1;

  if ((ext[0] == 'p' || ext[0] == 'P') &&
      (ext[1] == 'd' || ext[1] == 'D') &&
      (ext[2] == 'f' || ext[2] == 'F'))
    return embed_pdf(ctx, dc, st, xf, filename);
  else
    return embed_image(ctx, dc, st, xf, filename);
}

static cursor_t
parse_xform_or_dim(struct xform_spec *xf, cursor_t cur, cursor_t lim)
{
  //fprintf(stderr, "pdf xform: %.*s\n", (int)(lim - cur), cur);
  cursor_t i, f0, f1, f2, f3, f4, f5, mar;
  float r = 0, sx = 1.0, sy = 1.0;

  while (cur < lim)
  {
    /*!re2c

    " "
    { continue; }

    "rotate" ws+ @f0 float
    {
      r = pfloat(f0, lim);
      continue;
    }

    "clip" ws+ @f0 int
    {
      xf->clip = pint(f0, lim);
      continue;
    }

    "scale" ws+ @f0 float
    {
      sx = sy = pfloat(f0, lim);
      continue;
    }

    "xscale" ws+ @f0 float
    {
      sx = pfloat(f0, lim);
      continue;
    }

    "yscale" ws+ @f0 float
    {
      sy = pfloat(f0, lim);
      continue;
    }

    "width" ws+ @f0 dim
    {
      xf->width = pdim(f0, lim);
      continue;
    }

    "height" ws+ @f0 dim
    {
      xf->height = pdim(f0, lim);
      continue;
    }

    "depth" ws+ @f0 dim
    {
      xf->depth = pdim(f0, lim);
      continue;
    }

    "bbox" ws+ @f0 float
           ws+ @f1 float
           ws+ @f2 float
           ws+ @f3 float
    {
      xf->bbox.x0 = pfloat(f0, lim);
      xf->bbox.x1 = pfloat(f1, lim);
      xf->bbox.y0 = pfloat(f2, lim);
      xf->bbox.y1 = pfloat(f3, lim);
      continue;
    }

    "page" ws+ @f0 nat
    {
      xf->page = pint(f0, lim);
      continue;
    }

    "pagebox" ws+ @f0 ("mediabox" | "cropbox" | "artbox" | "bleedbox" | "trimbox")
    {
      int c = f0[0];
      switch (c)
      {
        case 'm':
          xf->pagebox = BOX_MEDIABOX;
          break;
        case 'c':
          xf->pagebox = BOX_CROPBOX;
          break;
        case 'a':
          xf->pagebox = BOX_ARTBOX;
          break;
        case 'b':
          xf->pagebox = BOX_BLEEDBOX;
          break;
        case 't':
          xf->pagebox = BOX_TRIMBOX;
          break;
      }
      continue;
    }

    "matrix" ws+ @f0 float
             ws+ @f1 float
             ws+ @f2 float
             ws+ @f3 float
             ws+ @f4 float
             ws+ @f5 float
    {
      xf->ctm.a = pfloat(f0, lim);
      xf->ctm.b = pfloat(f1, lim);
      xf->ctm.c = pfloat(f2, lim);
      xf->ctm.d = pfloat(f3, lim);
      xf->ctm.e = pfloat(f4, lim);
      xf->ctm.f = pfloat(f5, lim);
      continue;
    }

    ''
    { break; }

    */
  }

  // Not sure about order in which transformations should be applied...

  if (sx != 1.0 || sy != 1.0)
    xf->ctm = fz_pre_scale(xf->ctm, sx, sy);

  if (r)
    xf->ctm = fz_pre_rotate(xf->ctm, r);

  return cur;
}

static bool
pdf_btrans(dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim)
{
  if (st->gs_stack.depth >= st->gs_stack.limit)
    return 0;
  st->gs_stack.base[st->gs_stack.depth] = st->gs;
  st->gs_stack.depth += 1;

  st->gs.ctm = dvi_get_ctm(dc, st);
  st->gs.h = st->registers.h;
  st->gs.v = st->registers.v;

  if (cur != lim)
  {
    struct xform_spec xf = xform_spec();
    cur = parse_xform_or_dim(&xf, cur, lim);
    st->gs.ctm = fz_concat(xf.ctm, st->gs.ctm);
  }
  if (cur != lim)
    return unhandled("pdf btrans transformation", cur, lim, 0);
  return 1;
}

static bool
pdf_etrans(dvi_context *dc, dvi_state *st)
{
  if (st->gs_stack.depth == 0)
    return 0;
  st->gs_stack.depth -= 1;
  st->gs = st->gs_stack.base[st->gs_stack.depth];
  return 1;
}

static fz_path *get_path(fz_context *ctx, dvi_context *dc)
{
  if (!dc->path)
    dc->path = fz_new_path(ctx);
  return dc->path;
}

static void drop_path(fz_context *ctx, dvi_context *dc)
{
  if (dc->path)
  {
    fz_drop_path(ctx, dc->path);
    dc->path = NULL;
  }
}

/* Taudot (MIT): MuPDF's fz_stroke_state ends in a flexible dash array, so a stack copy has no room for the
   dashes and the memcpy overflowed (a fortify trap on any dashed TikZ line). Allocate one with room instead. */
static fz_stroke_state *new_stroke_state(fz_context *ctx, dvi_state *st)
{
  fz_stroke_state *stst = fz_new_stroke_state_with_dash_len(ctx, st->gs.dash_len);
  stst->linewidth = st->gs.line_width;
  stst->linejoin = (int)st->gs.line_join;
  stst->miterlimit = st->gs.miter_limit;
  stst->dash_cap = stst->start_cap = stst->end_cap = (int)st->gs.line_caps;
  stst->dash_len = st->gs.dash_len;
  memcpy(stst->dash_list, st->gs.dash, sizeof(float) * st->gs.dash_len);
  stst->dash_phase = st->gs.dash_phase;
  return stst;
}

static void stroke_path(fz_context *ctx, dvi_context *dc, dvi_state *st, fz_path *path, fz_matrix ctm,
                        const float *color)
{
  fz_stroke_state *stst = new_stroke_state(ctx, st);
  fz_try(ctx)
    fz_stroke_path(ctx, dc->dev, path, stst, ctm, device_cs(ctx), color, DVI_LINE_ALPHA(st), color_params);
  fz_always(ctx)
    fz_drop_stroke_state(ctx, stst);
  fz_catch(ctx)
    fz_rethrow(ctx);
}

static bool
pdf_code(fz_context *ctx, dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim);
static bool is_pdf_delim(char c);
static void paint_shading(fz_context *ctx, dvi_context *dc, dvi_state *st, const char *name);

/* Taudot (MIT, like this file): tiling patterns, as PGF's xetex driver writes them (\usetikzlibrary{patterns}):
 *   pdf:stream @pgfpatternobject3 (q 0.3985 w 0 0 m 3 3 l S Q) << /Type /Pattern /PatternType 1 /PaintType 2
 *     /BBox [...] /XStep x /YStep y /Matrix [...] >>
 *   pdf:put @pgfpatterns << /pgfpat3 @pgfpatternobject3 >>
 *   pdf:code /pgfprgb cs 0.55 0.55 0.55 /pgfpat3 scn ... f
 * TeXpresso ignored all three, so pattern fills came out solid black. A fill with a pattern clips to the path and
 * repeats the cell over it, drawing the cell's content through pdf_code in the colour given to scn
 * (PaintType 2) or its own colours (PaintType 1). */

static dvi_pattern *pattern_by_obj(fz_context *ctx, dvi_context *dc, const char *obj, size_t len, bool create)
{
  if (len == 0 || len >= sizeof(dc->patterns[0].obj))
    return NULL;
  for (int i = 0; i < dc->pattern_count; i++)
    if (strlen(dc->patterns[i].obj) == len && memcmp(dc->patterns[i].obj, obj, len) == 0)
      return &dc->patterns[i];
  if (!create || dc->pattern_count >= DVI_PATTERNS_MAX)
    return NULL;
  dvi_pattern *p = &dc->patterns[dc->pattern_count++];
  memset(p, 0, sizeof(*p));
  memcpy(p->obj, obj, len);
  p->matrix = fz_identity;
  return p;
}

static int pattern_by_name(dvi_context *dc, const char *name)
{
  for (int i = 0; i < dc->pattern_count; i++)
    if (strcmp(dc->patterns[i].name, name) == 0)
      return i;
  return -1;
}

/* Numbers after "key" in [cur, lim), skipping "[": returns how many were read (up to count). */
static int dict_numbers(cursor_t cur, cursor_t lim, const char *key, float *out, int count)
{
  size_t klen = strlen(key);
  const char *k = fz_memmem(cur, lim - cur, key, klen);
  while (k && k + klen < lim && !is_pdf_delim(k[klen]))
    k = fz_memmem(k + 1, lim - (k + 1), key, klen);
  if (!k)
    return 0;
  cursor_t p = k + klen;
  int n = 0;
  while (n < count && p < lim)
  {
    while (p < lim && (*p == ' ' || *p == '[' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    char buf[32];
    size_t i = 0;
    while (p + i < lim && i < sizeof(buf) - 1 && !is_pdf_delim(p[i]) && p[i] != ']') { buf[i] = p[i]; i++; }
    buf[i] = 0;
    char *end;
    float v = strtof(buf, &end);
    if (end == buf)
      break;
    out[n++] = v;
    p += i;
  }
  return n;
}

/* "pdf:stream @obj (content) << dict >>": keep it if it is a tiling pattern. */
static int pattern_stream(fz_context *ctx, dvi_context *dc, cursor_t cur, cursor_t lim)
{
  while (cur < lim && *cur == ' ') cur++;
  if (cur >= lim || *cur != '@')
    return -1;
  cursor_t obj = ++cur;
  while (cur < lim && !is_pdf_delim(*cur)) cur++;
  size_t obj_len = cur - obj;
  while (cur < lim && *cur == ' ') cur++;
  if (cur >= lim || *cur != '(')
    return -1;
  /* the content string: balanced parentheses, backslash escapes */
  cursor_t s = ++cur;
  int nest = 1;
  while (cur < lim)
  {
    if (*cur == '\\') { cur += 2; continue; }
    if (*cur == '(') nest++;
    else if (*cur == ')' && --nest == 0) break;
    cur++;
  }
  if (cur >= lim)
    return -1;
  cursor_t s_end = cur++;
  if (!fz_memmem(cur, lim - cur, "/PatternType 1", 14))
    return -1;
  dvi_pattern *p = pattern_by_obj(ctx, dc, obj, obj_len, 1);
  if (!p)
    return 1;
  char *content = fz_malloc(ctx, (s_end - s) + 1);
  size_t n = 0;
  for (cursor_t q = s; q < s_end; q++)
  {
    if (*q == '\\' && q + 1 < s_end)
    {
      q++;
      char c = *q;
      content[n++] = c == 'n' ? '\n' : c == 'r' ? '\r' : c == 't' ? '\t' : c;
    }
    else
      content[n++] = *q;
  }
  content[n] = 0;
  fz_free(ctx, p->content);
  p->content = content;
  float v[6];
  p->bbox = dict_numbers(cur, lim, "/BBox", v, 4) == 4 ? fz_make_rect(v[0], v[1], v[2], v[3]) : fz_empty_rect;
  p->xstep = dict_numbers(cur, lim, "/XStep", v, 1) == 1 ? v[0] : 0;
  p->ystep = dict_numbers(cur, lim, "/YStep", v, 1) == 1 ? v[0] : 0;
  p->matrix = dict_numbers(cur, lim, "/Matrix", v, 6) == 6 ? fz_make_matrix(v[0], v[1], v[2], v[3], v[4], v[5])
                                                           : fz_identity;
  p->paint_type = dict_numbers(cur, lim, "/PaintType", v, 1) == 1 ? (int)v[0] : 1;
  return 1;
}

/* In a pdf:put body, "/Name @obj" names a pattern object. */
static void scan_pattern_names(fz_context *ctx, dvi_context *dc, cursor_t cur, cursor_t lim)
{
  while (cur < lim)
  {
    if (*cur != '/') { cur++; continue; }
    cursor_t n = ++cur;
    while (cur < lim && !is_pdf_delim(*cur)) cur++;
    size_t nlen = cur - n;
    cursor_t q = cur;
    while (q < lim && *q == ' ') q++;
    if (q < lim && *q == '@' && nlen < sizeof(dc->patterns[0].name))
    {
      cursor_t o = ++q;
      while (q < lim && !is_pdf_delim(*q)) q++;
      if (fz_memmem(o, q - o, "pattern", 7))
      {
        dvi_pattern *p = pattern_by_obj(ctx, dc, o, q - o, 1);
        if (p)
        {
          memcpy(p->name, n, nlen);
          p->name[nlen] = 0;
        }
      }
      cur = q;
    }
  }
}

/* scn/sc with a pattern name last: the numbers before it are the colour of an uncoloured pattern. */
static void set_fill_scn(fz_context *ctx, dvi_context *dc, dvi_state *st, vstack *stack)
{
  val args = vstack_get_values(ctx, stack);
  int n = val_array_length(ctx, stack, args);
  float c[4];
  int nc = 0;
  const char *name = NULL;
  for (int i = 0; i < n; i++)
  {
    val v = val_array_get(ctx, stack, args, i);
    if (val_is_number(v) && nc < 4)
      c[nc++] = val_number(ctx, v);
    else if (val_is_name(v))
      name = val_as_name(ctx, stack, v);
  }
  if (nc == 1) color_set_gray(st->gs.colors.fill, c[0]);
  else if (nc == 3) color_set_rgb(st->gs.colors.fill, c[0], c[1], c[2]);
  else if (nc == 4) color_set_cmyk(ctx, st->gs.colors.fill, c[0], c[1], c[2], c[3]);
  if (!name)
    st->gs.fill_pattern = 0;
  else
  {
    int i = pattern_by_name(dc, name);
    st->gs.fill_pattern = (i >= 0 && dc->patterns[i].content) ? i + 1 : -1;
    if (st->gs.fill_pattern < 0)
      fprintf(stderr, "pdf scn: pattern /%s not defined (yet)\n", name);
  }
}

static void fill_pattern(fz_context *ctx, dvi_context *dc, dvi_state *st, fz_path *path, int even_odd,
                         fz_matrix ctm)
{
  dvi_pattern *pat = &dc->patterns[st->gs.fill_pattern - 1];
  float H = dc->page_height > 0 ? dc->page_height : 792;
  /* pattern space -> the page's default space (origin bottom left) -> our device space (origin top left) */
  fz_matrix ptm = fz_concat(pat->matrix, fz_make_matrix(1, 0, 0, -1, 0, H));
  fz_rect dev_area = fz_bound_path(ctx, path, NULL, ctm);
  if (fz_is_empty_rect(dev_area) || pat->xstep == 0 || pat->ystep == 0)
    return;
  fz_rect view = fz_transform_rect(dev_area, fz_invert_matrix(ptm));

  dvi_state cell = *st;
  cell.gs.fill_pattern = 0;
  cell.gs.dash_len = 0;
  cell.gs.line_width = 1;
  cell.gs.miter_limit = 10;
  cell.gs.line_join = 0;
  cell.gs.line_caps = 0;
  if (pat->paint_type == 2)
    memcpy(cell.gs.colors.line, st->gs.colors.fill, sizeof(cell.gs.colors.line));
  else
  {
    color_set_gray(cell.gs.colors.fill, 0);
    color_set_gray(cell.gs.colors.line, 0);
  }
  dvi_set_ctm(&cell, ptm);

  fz_path *outer = dc->path;
  dc->path = NULL;
  fz_clip_path(ctx, dc->dev, path, even_odd, ctm, fz_infinite_rect);
  fz_try(ctx)
  {
    /* Repeat the cell by hand over the area to fill, in pattern space. (fz_begin_tile drew nothing here; a loop
       also carries over to Phase B's backend as is.) */
    int i0 = (int)floorf((view.x0 - pat->bbox.x1) / pat->xstep), i1 = (int)ceilf((view.x1 - pat->bbox.x0) / pat->xstep);
    int j0 = (int)floorf((view.y0 - pat->bbox.y1) / pat->ystep), j1 = (int)ceilf((view.y1 - pat->bbox.y0) / pat->ystep);
    if ((double)(i1 - i0 + 1) * (j1 - j0 + 1) > 100000)
    {
      fprintf(stderr, "pdf pattern %s: too many cells, drawn as a tint\n", pat->obj);
      fz_fill_path(ctx, dc->dev, path, even_odd, ctm, device_cs(ctx), st->gs.colors.fill, 0.25f * DVI_FILL_ALPHA(st),
                   color_params);
    }
    else
      for (int j = j0; j <= j1; j++)
        for (int i = i0; i <= i1; i++)
        {
          dvi_set_ctm(&cell, fz_pre_translate(ptm, i * pat->xstep, j * pat->ystep));
          pdf_code(ctx, dc, &cell, pat->content, pat->content + strlen(pat->content));
        }
  }
  fz_always(ctx)
  {
    drop_path(ctx, dc);
    dc->path = outer;
    fz_pop_clip(ctx, dc->dev);
  }
  fz_catch(ctx)
    fz_rethrow(ctx);
}

/* Every path fill goes through here. */
static void fill_path(fz_context *ctx, dvi_context *dc, dvi_state *st, fz_path *path, int even_odd, fz_matrix ctm)
{
  if (st->gs.fill_pattern > 0)
    fill_pattern(ctx, dc, st, path, even_odd, ctm);
  else
    fz_fill_path(ctx, dc->dev, path, even_odd, ctm, device_cs(ctx), st->gs.colors.fill,
                 DVI_FILL_ALPHA(st) * (st->gs.fill_pattern < 0 ? 0.25f : 1.0f), color_params);
}

/* Taudot (MIT): B, B*, b and b*. With transparency, PDF paints the fill and the stroke as one knockout group, so
 * the stroke replaces the fill under it rather than compositing over it. */
static void fill_stroke_path(fz_context *ctx, dvi_context *dc, dvi_state *st, fz_path *path, int even_odd,
                             fz_matrix ctm)
{
  bool knockout = st->gs.fill_transp > 0 || st->gs.line_transp > 0;
  if (knockout)
  {
    fz_stroke_state *stst = new_stroke_state(ctx, st);
    fz_rect area;
    fz_try(ctx)
      area = fz_bound_path(ctx, path, stst, ctm);
    fz_always(ctx)
      fz_drop_stroke_state(ctx, stst);
    fz_catch(ctx)
      fz_rethrow(ctx);
    fz_begin_group(ctx, dc->dev, area, NULL, 0, 1, FZ_BLEND_NORMAL, 1);
  }
  fill_path(ctx, dc, st, path, even_odd, ctm);
  stroke_path(ctx, dc, st, path, ctm, st->gs.colors.line);
  if (knockout)
    fz_end_group(ctx, dc->dev);
}

/* Taudot (MIT, like this file): transparency. PGF's xetex driver and the transparent package set opacity with an
 * ExtGState: "pdf:put @pgfextgs << /pgf@ca0.5 << /ca 0.5 >> >>" (or "pdf:put @resources << /ExtGState << ... >> >>")
 * once, then "pdf:code /pgf@ca0.5 gs" at each use. We remember every dictionary that sets /ca or /CA, by name. */

static dvi_extgstate *extgs_entry(fz_context *ctx, dvi_context *dc, const char *name, size_t len, bool create)
{
  if (len >= sizeof(dc->extgs[0].name))
    return NULL;
  for (int i = 0; i < dc->extgs_count; i++)
    if (strlen(dc->extgs[i].name) == len && memcmp(dc->extgs[i].name, name, len) == 0)
      return &dc->extgs[i];
  if (!create || dc->extgs_count >= DVI_EXTGS_MAX)
    return NULL;
  dvi_extgstate *e = &dc->extgs[dc->extgs_count++];
  memcpy(e->name, name, len);
  e->name[len] = 0;
  e->ca = e->CA = -1;
  return e;
}

static bool is_pdf_delim(char c)
{
  return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '/' || c == '<' || c == '>' ||
         c == '[' || c == ']' || c == '(' || c == ')' || c == '{' || c == '}' || c == '%';
}

/* Scans the body of a pdf:put for "/Name << ... /ca x /CA y ... >>". Nested dictionaries are tracked, so
 * "/ExtGState << /TRP0.5 << /ca 0.5 >> >>" records TRP0.5. Other keys are skipped. */
static void scan_extgstates(fz_context *ctx, dvi_context *dc, cursor_t cur, cursor_t lim)
{
  cursor_t names[16]; size_t lens[16];
  int depth = 0;
  cursor_t pending = NULL; size_t pending_len = 0;
  while (cur < lim)
  {
    char c = *cur;
    if (c == '<' && cur + 1 < lim && cur[1] == '<')
    {
      if (depth < 16) { names[depth] = pending; lens[depth] = pending_len; }
      depth++;
      pending = NULL;
      cur += 2;
    }
    else if (c == '>' && cur + 1 < lim && cur[1] == '>')
    {
      if (depth > 0) depth--;
      pending = NULL;
      cur += 2;
    }
    else if (c == '/')
    {
      cursor_t n = ++cur;
      while (cur < lim && !is_pdf_delim(*cur)) cur++;
      size_t len = cur - n;
      bool fill = len == 2 && n[0] == 'c' && n[1] == 'a';
      bool line = len == 2 && n[0] == 'C' && n[1] == 'A';
      if ((fill || line) && depth >= 1 && depth <= 16 && names[depth - 1])
      {
        while (cur < lim && (*cur == ' ' || *cur == '\t' || *cur == '\n' || *cur == '\r')) cur++;
        char *end;
        char buf[32];
        size_t k = 0;
        while (cur + k < lim && k < sizeof(buf) - 1 && !is_pdf_delim(cur[k])) { buf[k] = cur[k]; k++; }
        buf[k] = 0;
        float v = strtof(buf, &end);
        if (end != buf)
        {
          dvi_extgstate *e = extgs_entry(ctx, dc, names[depth - 1], lens[depth - 1], 1);
          if (e)
          {
            if (v < 0) v = 0;
            if (v > 1) v = 1;
            if (fill) e->ca = v; else e->CA = v;
          }
        }
        cur += k;
        pending = NULL;
      }
      else
      {
        pending = n;
        pending_len = len;
      }
    }
    else
    {
      if (!(c == ' ' || c == '\t' || c == '\n' || c == '\r'))
        pending = NULL;
      cur++;
    }
  }
}

/* The "gs" operator: look the name up; for names never put (a page drawn before the one that put them), read the
 * value from the name the way PGF (pgf@ca0.5, pgf@CA0.5) and the transparent package (TRP0.5) spell it. */
static void set_extgstate(fz_context *ctx, dvi_context *dc, dvi_state *st, const char *name)
{
  float ca = -1, CA = -1;
  dvi_extgstate *e = extgs_entry(ctx, dc, name, strlen(name), 0);
  if (e)
    ca = e->ca, CA = e->CA;
  else if (strncmp(name, "pgf@ca", 6) == 0)
    ca = strtof(name + 6, NULL);
  else if (strncmp(name, "pgf@CA", 6) == 0)
    CA = strtof(name + 6, NULL);
  else if (strncmp(name, "TRP", 3) == 0)
    ca = CA = strtof(name + 3, NULL);
  else
    fprintf(stderr, "pdf gs: unknown ExtGState /%s\n", name);
  if (ca >= 0 || CA >= 0)
    dvi_context_flush_text(ctx, dc, st);
  if (ca >= 0)
    st->gs.fill_transp = 1.0f - fz_clamp(ca, 0, 1);
  if (CA >= 0)
    st->gs.line_transp = 1.0f - fz_clamp(CA, 0, 1);
}

static bool
pdf_code(fz_context *ctx, dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim)
{
  vstack *stack = vstack_new(ctx);
  fz_var(cur);
  fz_var(stack);

  // fprintf(stderr, "pdf code: %.*s\n", (int)(lim - cur), cur);
  fz_try(ctx)
  {
    enum PDF_OP op;
    do {
      cursor_t cur0 = cur;
      op = pdf_parse_command(ctx, stack, &cur, lim);
      switch (op)
      {
        case PDF_OP_cm:
        {
          float fmat[6];
          vstack_get_floats(ctx, stack, fmat, 6);
          fz_matrix mat;
          mat.a = fmat[0]; mat.b = fmat[1]; mat.c = fmat[2];
          mat.d = fmat[3]; mat.e = fmat[4]; mat.f = fmat[5];
          fz_matrix ctm = fz_concat(mat, dvi_get_ctm(dc, st));
          dvi_set_ctm(st, ctm);
          break;
        }
        case PDF_OP_q:
        {
          if (st->gs_stack.depth >= st->gs_stack.limit)
            fz_throw(ctx, 0, "PDF q: stack overflow");
          st->gs_stack.base[st->gs_stack.depth] = st->gs;
          st->gs_stack.depth += 1;
          break;
        }
        case PDF_OP_Q:
        {
          if (st->gs_stack.depth == 0)
            fz_throw(ctx, 0, "PDF Q: stack underflow");
          st->gs_stack.depth -= 1;

          int clip_depth0 = st->gs.clip_depth;
          st->gs = st->gs_stack.base[st->gs_stack.depth];
          if (dc->dev)
            for (int i = st->gs.clip_depth; i < clip_depth0; ++i)
              fz_pop_clip(ctx, dc->dev);
          break;
        }
        case PDF_OP_G:
        {
          float c[1];
          vstack_get_floats(ctx, stack, c, 1);
          color_set_gray(st->gs.colors.line, c[0]);
          break;
        }
        case PDF_OP_g:
        {
          float c[1];
          vstack_get_floats(ctx, stack, c, 1);
          color_set_gray(st->gs.colors.fill, c[0]);
          st->gs.fill_pattern = 0;
          break;
        }
        case PDF_OP_RG:
        {
          float c[3];
          vstack_get_floats(ctx, stack, c, 3);
          color_set_rgb(st->gs.colors.line, c[0], c[1], c[2]);
          break;
        }
        case PDF_OP_rg:
        {
          float c[3];
          vstack_get_floats(ctx, stack, c, 3);
          color_set_rgb(st->gs.colors.fill, c[0], c[1], c[2]);
          st->gs.fill_pattern = 0;
          break;
        }
        case PDF_OP_K:
        {
          float c[4];
          vstack_get_floats(ctx, stack, c, 4);
          color_set_cmyk(ctx, st->gs.colors.line, c[0], c[1], c[2], c[3]);
          break;
        }
        case PDF_OP_k:
        {
          float c[4];
          vstack_get_floats(ctx, stack, c, 4);
          color_set_cmyk(ctx, st->gs.colors.fill, c[0], c[1], c[2], c[3]);
          st->gs.fill_pattern = 0;
          break;
        }

        case PDF_OP_w:
        {
          vstack_get_floats(ctx, stack, &st->gs.line_width, 1);
          break;
        }

        case PDF_OP_j:
        {
          float c[1];
          vstack_get_floats(ctx, stack, c, 1);
          st->gs.line_join = c[0];
          break;
        }

        case PDF_OP_J:
        {
          float c[1];
          vstack_get_floats(ctx, stack, c, 1);
          st->gs.line_caps = c[0];
          break;
        }

        case PDF_OP_M:
        {
          float c[1];
          vstack_get_floats(ctx, stack, c, 1);
          st->gs.miter_limit = c[0];
          break;
        }

        case PDF_OP_m:
        {
          float c[2];
          vstack_get_floats(ctx, stack, c, 2);
          fz_moveto(ctx, get_path(ctx, dc), c[0], c[1]);
          break;
        }

        case PDF_OP_l:
        {
          float c[2];
          vstack_get_floats(ctx, stack, c, 2);
          fz_lineto(ctx, get_path(ctx, dc), c[0], c[1]);
          break;
        }

        case PDF_OP_c:
        {
          float c[6];
          vstack_get_floats(ctx, stack, c, 6);
          fz_curveto(ctx, get_path(ctx, dc), c[0], c[1], c[2], c[3], c[4], c[5]);
          break;
        }

        case PDF_OP_b:
          if (dc->dev)
          {
            fz_matrix ctm = dvi_get_ctm(dc, st);
            fz_path *path = get_path(ctx, dc);
            fz_closepath(ctx, path);
            fill_stroke_path(ctx, dc, st, path, 0, ctm);
          }
          drop_path(ctx, dc);
          break;

        case PDF_OP_b_star:
          if (dc->dev)
          {
            fz_matrix ctm = dvi_get_ctm(dc, st);
            fz_path *path = get_path(ctx, dc);
            fz_closepath(ctx, path);
            fill_stroke_path(ctx, dc, st, path, 1, ctm);
          }
          drop_path(ctx, dc);
          break;

        case PDF_OP_B:
          if (dc->dev)
          {
            fz_matrix ctm = dvi_get_ctm(dc, st);
            fz_path *path = get_path(ctx, dc);
            fill_stroke_path(ctx, dc, st, path, 0, ctm);
          }
          drop_path(ctx, dc);
          break;

        case PDF_OP_B_star:
          if (dc->dev)
          {
            fz_matrix ctm = dvi_get_ctm(dc, st);
            fz_path *path = get_path(ctx, dc);
            fill_stroke_path(ctx, dc, st, path, 1, ctm);
          }
          drop_path(ctx, dc);
          break;

        case PDF_OP_f:
        case PDF_OP_F:
          if (dc->dev)
          {
            fz_matrix ctm = dvi_get_ctm(dc, st);
            fz_path *path = get_path(ctx, dc);
            fill_path(ctx, dc, st, path, 0, ctm);
          }
          drop_path(ctx, dc);
          break;

        case PDF_OP_f_star:
          if (dc->dev)
          {
            fz_matrix ctm = dvi_get_ctm(dc, st);
            fz_path *path = get_path(ctx, dc);
            fill_path(ctx, dc, st, path, 1, ctm);
          }
          drop_path(ctx, dc);
          break;

        case PDF_OP_S:
          if (dc->dev)
          {
            fz_matrix ctm = dvi_get_ctm(dc, st);
            fz_path *path = get_path(ctx, dc);
            stroke_path(ctx, dc, st, path, ctm, st->gs.colors.line);
          }
          drop_path(ctx, dc);
          break;

        case PDF_OP_s:
          if (dc->dev)
          {
            fz_matrix ctm = dvi_get_ctm(dc, st);
            fz_path *path = get_path(ctx, dc);
            fz_closepath(ctx, path);
            stroke_path(ctx, dc, st, path, ctm, st->gs.colors.line);
          }
          drop_path(ctx, dc);
          break;

        case PDF_OP_h:
        {
          fz_path *path = get_path(ctx, dc);
          fz_closepath(ctx, path);
          break;
        }

        case PDF_OP_re:
        {
          float c[4];
          vstack_get_floats(ctx, stack, c, 4);
          fz_rectto(ctx, get_path(ctx, dc), c[0], c[1], c[0] + c[2], c[1] + c[3]);
          break;
        }

        case PDF_OP_n:
        {
          drop_path(ctx, dc);
          break;
        }

        case PDF_OP_W:
          if (dc->dev)
          {
            fz_matrix ctm = dvi_get_ctm(dc, st);
            fz_clip_path(ctx, dc->dev, get_path(ctx, dc), 0, ctm,
                         fz_infinite_rect);
            st->gs.clip_depth += 1;
          }
          break;

        case PDF_OP_W_star:
          if (dc->dev)
          {
            fz_matrix ctm = dvi_get_ctm(dc, st);
            fz_clip_path(ctx, dc->dev, get_path(ctx, dc), 1, ctm,
                         fz_infinite_rect);
            st->gs.clip_depth += 1;
          }
          break;

        case PDF_OP_d:
        {
          val v[2];
          vstack_get_arguments(ctx, stack, v, 2);
          st->gs.dash_len = val_array_length(ctx, stack, v[0]);
          if (st->gs.dash_len > 4) st->gs.dash_len = 4;
          for (int i = 0; i < st->gs.dash_len; ++i)
            st->gs.dash[i] = val_number(ctx, val_array_get(ctx, stack, v[0], i));
          st->gs.dash_phase = val_number(ctx, v[1]);
          break;
        }

        case PDF_OP_sh:
        {
          val v[1];
          vstack_get_arguments(ctx, stack, v, 1);
          paint_shading(ctx, dc, st, val_as_name(ctx, stack, v[0]));
          break;
        }

        case PDF_OP_cs:
        case PDF_OP_CS:
          vstack_get_values(ctx, stack);  /* the colour comes with sc/scn */
          break;

        case PDF_OP_sc:
        case PDF_OP_scn:
          set_fill_scn(ctx, dc, st, stack);
          break;

        case PDF_OP_SC:
        case PDF_OP_SCN:
        {
          val args = vstack_get_values(ctx, stack);
          int n = val_array_length(ctx, stack, args);
          float c[4];
          int nc = 0;
          for (int i = 0; i < n && nc < 4; i++)
          {
            val v = val_array_get(ctx, stack, args, i);
            if (val_is_number(v)) c[nc++] = val_number(ctx, v);
          }
          if (nc == 1) color_set_gray(st->gs.colors.line, c[0]);
          else if (nc == 3) color_set_rgb(st->gs.colors.line, c[0], c[1], c[2]);
          else if (nc == 4) color_set_cmyk(ctx, st->gs.colors.line, c[0], c[1], c[2], c[3]);
          break;
        }

        case PDF_OP_gs:
        {
          val v[1];
          vstack_get_arguments(ctx, stack, v, 1);
          set_extgstate(ctx, dc, st, val_as_name(ctx, stack, v[0]));
          break;
        }

        case PDF_OP_ri:
        case PDF_OP_i:
        case PDF_OP_v:
        case PDF_OP_y:
        case PDF_OP_BT:
        case PDF_OP_ET:
        case PDF_OP_Tc:
        case PDF_OP_Tw:
        case PDF_OP_Tz:
        case PDF_OP_TL:
        case PDF_OP_Tf:
        case PDF_OP_Tr:
        case PDF_OP_Ts:
        case PDF_OP_Td:
        case PDF_OP_TD:
        case PDF_OP_Tm:
        case PDF_OP_T_star:
        case PDF_OP_Tj:
        case PDF_OP_TJ:
        case PDF_OP_squote:
        case PDF_OP_dquote:
        case PDF_OP_d0:
        case PDF_OP_d1:
        case PDF_OP_Do:
        case PDF_OP_MP:
        case PDF_OP_DP:
        case PDF_OP_BMC:
        case PDF_OP_BDC:
        case PDF_OP_EMC:
        case PDF_OP_BX:
        case PDF_OP_EX:
        default:
          fprintf(stderr, "pdf unhandled op %s in:\n%.*s\n", pdf_op_name(op),
                  (int)(cur - cur0), cur0);
          break;

        case PDF_NONE:
          break;
      }
    } while (op != PDF_NONE);
  }
  fz_always(ctx)
  {
    vstack_free(ctx, stack);
  }
  fz_catch(ctx)
  {
    return 0;
  }
  return 1;
}

static cursor_t parse_pdf_string(char *buf, char *end, cursor_t cur, cursor_t lim)
{
  if (buf >= end)
    return cur;

  int nesting = 1;
  end -= 1;
  while (cur < lim)
  {
    if (*cur == '(')
      nesting += 1;
    else if (*cur == ')')
    {
      nesting -= 1;
      if (nesting == 0)
        break;
    }
    else if (*cur == '\\')
    {
      cur += 1;
      if (cur >= lim)
        break;
    }
    if (buf < end)
    {
      *buf = *cur;
      buf += 1;
    }
    cur += 1;
  }
  *buf = 0;
  return cur;
}

static bool
dvi_exec_pdf(fz_context *ctx, dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim)
{
  cursor_t mar, i, f0, f1, f2, f3, f4, f5, pxform = NULL, pstart, pend;

  /*!re2c

  "pagesize" ws+ "width" ws+ @f0 dim
             ws+ "height" ws+ @f1 dim
  { dc->page_height = pdim(f1, lim); return 1; }

  "pagesize" ws+ "default"
  { dc->page_height = 792; return 1; }

  @f0 "image" ws+ @pxform ([a-z] | ws | float)* @pstart "("
  {
    struct xform_spec xf = xform_spec();
    pxform = parse_xform_or_dim(&xf, pxform, pstart);
    if (pxform != pstart)
      fprintf(stderr, "pdf unhandled transformation: %.*s\n",
              (int)(pstart - pxform), pxform);
    char filename[2048];
    cur = parse_pdf_string(filename, filename + 2048, cur, lim);
    if (!embed_graphics(ctx, dc, st, &xf, filename))
    {
      fprintf(stderr, "error rendering image: %.*s", (int)(lim-f0), f0);
      return 0;
    }
    else
      return 1;
  }

  ("begintransform" | "btrans" | "bt") ws*
  { return pdf_btrans(dc, st, cur, lim); }

  ("endtransform" | "etrans" | "et")
  { return pdf_etrans(dc, st); }

  @f0 ("bcontent" | "econtent") @f1
  {
    if (f1 != lim)
      fprintf(stderr, "unhandled pdf content: %.*s\n",
              (int)(lim - f0), f0);
    return 1;
  }

  ("begincolor" | "bcolor" | "bc") ws*
  (@f4 float | "[" ws* @f0 float (ws+ @f1 float ws+ @f2 float (ws+ @f3 float)?)? ws* "]")
  {
    if (!colorstack_push(ctx, dc, st, -1))
      return 0;
    if (f3)
      color_set_cmyk(ctx, st->gs.colors.fill, pfloat(f0, lim), pfloat(f1, lim), pfloat(f2, lim), pfloat(f3, lim));
    else if (f1)
      color_set_rgb(st->gs.colors.fill, pfloat(f0, lim), pfloat(f1, lim), pfloat(f2, lim));
    else
      color_set_gray(st->gs.colors.fill, pfloat(f4 ? f4 : f0, lim));
    return 1;
  }

  ("endcolor" | "ecolor" | "ec")
  {
    return colorstack_pop(ctx, dc, st, -1);
  }

  "code"
  { return pdf_code(ctx, dc, st, cur, lim); }

  ''
  { return unhandled("pdf special", cur, lim, 0); }

  */
}

/* Taudot (MIT, like this file): shadings. PGF's xetex driver puts each \shade in a form XObject:
 *   pdf:bxobj @pgfshade1 width W height H
 *   pdf:put @resources << /Shading << /Sh << /ShadingType 2 /ColorSpace /DeviceRGB /Domain [...] /Coords [...]
 *     /Function << /FunctionType 3 /Functions [<< /FunctionType 2 ... >> ...] /Bounds [...] /Encode [...] >>
 *     /Extend [false false] >> >> >>
 *   pdf:code /Sh sh
 *   pdf:exobj
 * and draws it with pdf:uxobj under a clip and a cm that stretches or turns it. We read the dictionary with a small
 * PDF object reader, sample its function (types 2 and 3, as one function or one per component) into MuPDF's
 * 256-entry table, and build an axial (2) or radial (3) fz_shade for "sh". */

typedef struct pobj pobj;
enum { POBJ_NULL, POBJ_NUM, POBJ_BOOL, POBJ_NAME, POBJ_ARRAY, POBJ_DICT, POBJ_OTHER };
struct pobj
{
  int kind;
  float num;
  char name[48];      /* a name's text; for a dict entry, its key */
  int n;
  pobj *items;        /* array items, or dict values (each with its key in name) */
};

static void pobj_free(fz_context *ctx, pobj *o)
{
  if (o->items)
  {
    for (int i = 0; i < o->n; i++)
      pobj_free(ctx, &o->items[i]);
    fz_free(ctx, o->items);
  }
  o->items = NULL;
  o->n = 0;
}

static void pobj_skip_ws(cursor_t *cur, cursor_t lim)
{
  while (*cur < lim && (**cur == ' ' || **cur == '\t' || **cur == '\n' || **cur == '\r'))
    (*cur)++;
}

static void pobj_name_into(char *buf, size_t size, cursor_t *cur, cursor_t lim)
{
  size_t k = 0;
  while (*cur < lim && !is_pdf_delim(**cur))
  {
    if (k + 1 < size) buf[k++] = **cur;
    (*cur)++;
  }
  buf[k] = 0;
}

static void pobj_append(fz_context *ctx, pobj *o, int *cap, pobj item)
{
  if (o->n == *cap)
  {
    *cap = *cap ? *cap * 2 : 8;
    o->items = fz_realloc(ctx, o->items, sizeof(pobj) * *cap);
  }
  o->items[o->n++] = item;
}

/* Reads one object at *cur. Depth-limited; anything unknown (strings, @refs, operators) becomes POBJ_OTHER. */
static pobj pobj_read(fz_context *ctx, cursor_t *cur, cursor_t lim, int depth)
{
  pobj o = {0};
  pobj_skip_ws(cur, lim);
  if (*cur >= lim || depth > 16)
    return o;
  char c = **cur;
  if (c == '/')
  {
    (*cur)++;
    o.kind = POBJ_NAME;
    pobj_name_into(o.name, sizeof(o.name), cur, lim);
  }
  else if (c == '[')
  {
    (*cur)++;
    o.kind = POBJ_ARRAY;
    int cap = 0;
    for (;;)
    {
      pobj_skip_ws(cur, lim);
      if (*cur >= lim) break;
      if (**cur == ']') { (*cur)++; break; }
      cursor_t before = *cur;
      pobj item = pobj_read(ctx, cur, lim, depth + 1);
      if (*cur == before) (*cur)++;
      pobj_append(ctx, &o, &cap, item);
    }
  }
  else if (c == '<' && *cur + 1 < lim && (*cur)[1] == '<')
  {
    *cur += 2;
    o.kind = POBJ_DICT;
    int cap = 0;
    for (;;)
    {
      pobj_skip_ws(cur, lim);
      if (*cur >= lim) break;
      if (**cur == '>' && *cur + 1 < lim && (*cur)[1] == '>') { *cur += 2; break; }
      if (**cur != '/') { (*cur)++; continue; }
      (*cur)++;
      char key[48];
      pobj_name_into(key, sizeof(key), cur, lim);
      pobj item = pobj_read(ctx, cur, lim, depth + 1);
      if (item.kind != POBJ_NAME)
        memcpy(item.name, key, sizeof(key));
      else
      {
        /* a name value: the entry keeps the key, and the value is its only child */
        pobj v = item;
        item = (pobj){0};
        item.kind = POBJ_NAME;
        memcpy(item.name, key, sizeof(key));
        item.n = 1;
        item.items = fz_malloc(ctx, sizeof(pobj));
        item.items[0] = v;
      }
      pobj_append(ctx, &o, &cap, item);
    }
  }
  else if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.')
  {
    char buf[32];
    size_t k = 0;
    while (*cur < lim && !is_pdf_delim(**cur) && k + 1 < sizeof(buf)) buf[k++] = *(*cur)++;
    buf[k] = 0;
    o.kind = POBJ_NUM;
    o.num = strtof(buf, NULL);
  }
  else if (lim - *cur >= 4 && memcmp(*cur, "true", 4) == 0)
  {
    *cur += 4; o.kind = POBJ_BOOL; o.num = 1;
  }
  else if (lim - *cur >= 5 && memcmp(*cur, "false", 5) == 0)
  {
    *cur += 5; o.kind = POBJ_BOOL; o.num = 0;
  }
  else
  {
    o.kind = POBJ_OTHER;
    if (c == '(')
    {
      int nest = 0;
      while (*cur < lim)
      {
        char x = *(*cur)++;
        if (x == '\\') { if (*cur < lim) (*cur)++; }
        else if (x == '(') nest++;
        else if (x == ')' && --nest == 0) break;
      }
    }
    else
      while (*cur < lim && !is_pdf_delim(**cur)) (*cur)++;
  }
  return o;
}

/* A dict entry, or NULL. For name values the value is the entry's only child. */
static const pobj *pobj_get(const pobj *dict, const char *key)
{
  if (!dict || dict->kind != POBJ_DICT)
    return NULL;
  for (int i = 0; i < dict->n; i++)
    if (strcmp(dict->items[i].name, key) == 0)
      return dict->items[i].kind == POBJ_NAME ? &dict->items[i].items[0] : &dict->items[i];
  return NULL;
}

static float pobj_num_at(const pobj *a, int i, float dflt)
{
  if (!a || a->kind != POBJ_ARRAY || i >= a->n || a->items[i].kind == POBJ_ARRAY) return dflt;
  return (a->items[i].kind == POBJ_NUM || a->items[i].kind == POBJ_BOOL) ? a->items[i].num : dflt;
}

/* Evaluates a type 2 or 3 function at t into out[0..n). Returns 0 for other types. */
static bool shade_fn_eval(const pobj *fn, float t, float *out, int n, int depth)
{
  const pobj *type = pobj_get(fn, "FunctionType");
  const pobj *domain = pobj_get(fn, "Domain");
  float d0 = pobj_num_at(domain, 0, 0), d1 = pobj_num_at(domain, 1, 1);
  if (t < d0) t = d0;
  if (t > d1) t = d1;
  if (!type || depth > 8)
    return 0;
  if ((int)type->num == 2)
  {
    const pobj *c0 = pobj_get(fn, "C0"), *c1 = pobj_get(fn, "C1"), *N = pobj_get(fn, "N");
    float e = N ? N->num : 1;
    float x = (e == 1) ? t : powf(t, e);
    for (int i = 0; i < n; i++)
    {
      float a = pobj_num_at(c0, i, 0), b = pobj_num_at(c1, i, 1);
      out[i] = a + x * (b - a);
    }
    return 1;
  }
  if ((int)type->num == 3)
  {
    const pobj *fns = pobj_get(fn, "Functions"), *bounds = pobj_get(fn, "Bounds"), *encode = pobj_get(fn, "Encode");
    if (!fns || fns->kind != POBJ_ARRAY || fns->n == 0)
      return 0;
    int k = fns->n, i = 0;
    while (i < k - 1 && t >= pobj_num_at(bounds, i, d1))
      i++;
    float lo = i == 0 ? d0 : pobj_num_at(bounds, i - 1, d0);
    float hi = i == k - 1 ? d1 : pobj_num_at(bounds, i, d1);
    float e0 = pobj_num_at(encode, 2 * i, 0), e1 = pobj_num_at(encode, 2 * i + 1, 1);
    float u = hi == lo ? e0 : e0 + (t - lo) * (e1 - e0) / (hi - lo);
    return shade_fn_eval(&fns->items[i], u, out, n, depth + 1);
  }
  return 0;
}

static fz_colorspace *shade_colorspace(fz_context *ctx, const pobj *cs)
{
  if (cs && strcmp(cs->name, "DeviceGray") == 0) return fz_device_gray(ctx);
  if (cs && strcmp(cs->name, "DeviceCMYK") == 0) return fz_device_cmyk(ctx);
  return fz_device_rgb(ctx);
}

/* Builds an fz_shade from a shading dictionary; NULL if it isn't one we draw. */
static fz_shade *build_shade(fz_context *ctx, const pobj *dict)
{
  const pobj *type = pobj_get(dict, "ShadingType");
  int t = type ? (int)type->num : 0;
  if (t != 2 && t != 3)
  {
    fprintf(stderr, "pdf shading: type %d not handled\n", t);
    return NULL;
  }
  fz_colorspace *cs = shade_colorspace(ctx, pobj_get(dict, "ColorSpace"));
  int n = fz_colorspace_n(ctx, cs);
  const pobj *fn = pobj_get(dict, "Function");
  const pobj *domain = pobj_get(dict, "Domain");
  const pobj *coords = pobj_get(dict, "Coords");
  const pobj *extend = pobj_get(dict, "Extend");
  if (!fn || !coords)
    return NULL;
  float d0 = pobj_num_at(domain, 0, 0), d1 = pobj_num_at(domain, 1, 1);

  fz_shade *shade = fz_malloc_struct(ctx, fz_shade);
  FZ_INIT_STORABLE(shade, 1, fz_drop_shade_imp);
  shade->type = t == 2 ? FZ_LINEAR : FZ_RADIAL;
  shade->colorspace = fz_keep_colorspace(ctx, cs);
  shade->matrix = fz_identity;
  shade->bbox = fz_infinite_rect;
  shade->function_stride = n + 1;
  shade->function = fz_malloc(ctx, sizeof(float) * 256 * shade->function_stride);
  bool ok = 1;
  for (int i = 0; i < 256 && ok; i++)
  {
    float x = d0 + (i / 255.0f) * (d1 - d0);
    float *out = shade->function + i * shade->function_stride;
    if (fn->kind == POBJ_ARRAY)
      for (int k = 0; k < n && ok; k++)
        ok = k < fn->n && shade_fn_eval(&fn->items[k], x, &out[k], 1, 0);
    else
      ok = shade_fn_eval(fn, x, out, n, 0);
    out[n] = 1;
  }
  if (!ok)
  {
    fprintf(stderr, "pdf shading: function not handled\n");
    fz_drop_shade(ctx, shade);
    return NULL;
  }
  if (t == 2)
  {
    shade->u.l_or_r.coords[0][0] = pobj_num_at(coords, 0, 0);
    shade->u.l_or_r.coords[0][1] = pobj_num_at(coords, 1, 0);
    shade->u.l_or_r.coords[1][0] = pobj_num_at(coords, 2, 0);
    shade->u.l_or_r.coords[1][1] = pobj_num_at(coords, 3, 0);
  }
  else
    for (int k = 0; k < 6; k++)
      shade->u.l_or_r.coords[k / 3][k % 3] = pobj_num_at(coords, k, 0);
  shade->u.l_or_r.extend[0] = pobj_num_at(extend, 0, 0) != 0;
  shade->u.l_or_r.extend[1] = pobj_num_at(extend, 1, 0) != 0;
  return shade;
}

static void register_shade(fz_context *ctx, dvi_context *dc, const char *name, fz_shade *shade)
{
  for (int i = 0; i < dc->shade_count; i++)
    if (strcmp(dc->shades[i].name, name) == 0)
    {
      fz_drop_shade(ctx, dc->shades[i].shade);
      dc->shades[i].shade = shade;
      return;
    }
  if (dc->shade_count >= DVI_SHADES_MAX || strlen(name) >= sizeof(dc->shades[0].name))
  {
    fz_drop_shade(ctx, shade);
    return;
  }
  strcpy(dc->shades[dc->shade_count].name, name);
  dc->shades[dc->shade_count++].shade = shade;
}

/* A pdf:put body "@obj << ... >>": every "/Name << /ShadingType ... >>" under a /Shading key, or at the top. */
static void scan_shadings(fz_context *ctx, dvi_context *dc, cursor_t cur, cursor_t lim)
{
  if (!fz_memmem(cur, lim - cur, "/ShadingType", 12))
    return;
  const char *p = memchr(cur, '<', lim - cur);
  if (!p)
    return;
  cur = p;
  pobj top = {0};
  fz_try(ctx)
  {
    top = pobj_read(ctx, &cur, lim, 0);
    const pobj *sh = pobj_get(&top, "Shading");
    const pobj *where = (sh && sh->kind == POBJ_DICT) ? sh : &top;
    for (int i = 0; where->kind == POBJ_DICT && i < where->n; i++)
    {
      const pobj *e = &where->items[i];
      if (e->kind == POBJ_DICT && pobj_get(e, "ShadingType"))
      {
        fz_shade *shade = build_shade(ctx, e);
        if (shade)
          register_shade(ctx, dc, e->name, shade);
      }
    }
  }
  fz_always(ctx)
    pobj_free(ctx, &top);
  fz_catch(ctx)
    fz_rethrow(ctx);
}

static void paint_shading(fz_context *ctx, dvi_context *dc, dvi_state *st, const char *name)
{
  for (int i = dc->shade_count - 1; i >= 0; i--)
    if (strcmp(dc->shades[i].name, name) == 0)
    {
      if (dc->dev)
        fz_fill_shade(ctx, dc->dev, dc->shades[i].shade, dvi_get_ctm(dc, st), DVI_FILL_ALPHA(st), color_params);
      return;
    }
  fprintf(stderr, "pdf sh: no shading /%s\n", name);
}

/* Taudot (MIT, like this file): form XObjects, which PGF uses for transparency groups (\begin{scope}[transparency
 * group, opacity=...]): "pdf:bxobj @name bbox ...", the content, "pdf:exobj <</Group << /S /Transparency ... >> >>",
 * and later "pdf:uxobj @name" where it is drawn, after a "gs" that sets the group's opacity. The content is
 * recorded into a display list at the point of bxobj, then replayed at uxobj under the current CTM, inside a
 * group with the current fill alpha. Forms live for the page. */

static cursor_t parse_obj_name(cursor_t cur, cursor_t lim, char *buf, size_t size)
{
  while (cur < lim && *cur == ' ') cur++;
  size_t k = 0;
  while (cur < lim && *cur != ' ' && *cur != '<' && k + 1 < size)
    buf[k++] = *cur++;
  buf[k] = 0;
  return cur;
}

static bool form_begin(fz_context *ctx, dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim)
{
  dvi_context_flush_text(ctx, dc, st);
  if (dc->form_depth >= DVI_FORM_DEPTH)
  {
    fprintf(stderr, "pdf:bxobj: forms nested too deep\n");
    return 0;
  }
  int i = dc->form_depth;
  parse_obj_name(cur, lim, dc->form_stack[i].name, sizeof(dc->form_stack[i].name));
  dc->form_stack[i].base = dvi_get_ctm(dc, st);
  dc->form_stack[i].fill_transp = st->gs.fill_transp;
  dc->form_stack[i].line_transp = st->gs.line_transp;
  dc->form_stack[i].saved_dev = dc->dev;
  dc->form_stack[i].list = NULL;
  if (dc->dev)
  {
    fz_display_list *list = fz_new_display_list(ctx, fz_infinite_rect);
    fz_try(ctx)
      dc->dev = fz_new_list_device(ctx, list);
    fz_catch(ctx)
    {
      fz_drop_display_list(ctx, list);
      fz_rethrow(ctx);
    }
    dc->form_stack[i].list = list;
  }
  dc->form_depth = i + 1;
  /* A form's content stream starts opaque. */
  st->gs.fill_transp = st->gs.line_transp = 0;
  return 1;
}

static bool form_end(fz_context *ctx, dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim)
{
  dvi_context_flush_text(ctx, dc, st);
  if (dc->form_depth == 0)
  {
    fprintf(stderr, "pdf:exobj without pdf:bxobj\n");
    return 0;
  }
  int i = --dc->form_depth;
  st->gs.fill_transp = dc->form_stack[i].fill_transp;
  st->gs.line_transp = dc->form_stack[i].line_transp;
  fz_display_list *list = dc->form_stack[i].list;
  if (list)
  {
    fz_device *list_dev = dc->dev;
    dc->dev = dc->form_stack[i].saved_dev;
    fz_try(ctx)
      fz_close_device(ctx, list_dev);
    fz_always(ctx)
      fz_drop_device(ctx, list_dev);
    fz_catch(ctx)
    {
      fz_drop_display_list(ctx, list);
      fz_rethrow(ctx);
    }
  }
  if (!list)
    return 1;
  if (dc->form_count >= DVI_FORMS_MAX)
  {
    fprintf(stderr, "pdf:exobj: too many forms on this page\n");
    fz_drop_display_list(ctx, list);
    return 0;
  }
  dvi_form *f = &dc->forms[dc->form_count++];
  memcpy(f->name, dc->form_stack[i].name, sizeof(f->name));
  f->list = list;
  f->base = dc->form_stack[i].base;
  size_t n = lim - cur;
  f->group = fz_memmem(cur, n, "/Transparency", 13) != NULL;
  f->isolated = fz_memmem(cur, n, "/I true", 7) != NULL;
  f->knockout = fz_memmem(cur, n, "/K true", 7) != NULL;
  return 1;
}

static bool form_use(fz_context *ctx, dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim)
{
  dvi_context_flush_text(ctx, dc, st);
  char name[64];
  parse_obj_name(cur, lim, name, sizeof(name));
  dvi_form *f = NULL;
  for (int i = dc->form_count - 1; i >= 0; i--)
    if (strcmp(dc->forms[i].name, name) == 0) { f = &dc->forms[i]; break; }
  if (!f)
  {
    if (dc->dev)
      fprintf(stderr, "pdf:uxobj %s: no such form on this page\n", name);
    return 1;
  }
  if (!dc->dev)
    return 1;
  /* recorded in device space under base; now drawn under the current CTM, which may scale or turn it */
  fz_matrix shift = fz_concat(fz_invert_matrix(f->base), dvi_get_ctm(dc, st));
  float alpha = DVI_FILL_ALPHA(st);
  bool group = f->group || alpha < 1;
  if (group)
  {
    fz_rect area = fz_transform_rect(fz_bound_display_list(ctx, f->list), shift);
    fz_begin_group(ctx, dc->dev, area, NULL, f->isolated, f->knockout, FZ_BLEND_NORMAL, alpha);
  }
  fz_run_display_list(ctx, f->list, dc->dev, shift, fz_infinite_rect, NULL);
  if (group)
    fz_end_group(ctx, dc->dev);
  return 1;
}

/* Taudot (MIT, like this file): the specials graphicx's xetex.def emits to clip
 * an included PDF (trim= or viewport= with clip): "x:gsave", then
 * "pdf:literal 0 -D W H re W n", the figure, then "x:grestore". Without them the
 * whole page of the figure is drawn over the text around it. gsave/grestore
 * act like PDF q/Q, and a plain literal (drawn at the current point) like
 * pdf:code. "pdf:literal direct": see pdf_direct; "pdf:literal page" stays unhandled.
 * Returns -1 when the special is none of these. */
/* Taudot (MIT): "pdf:literal direct": PDF code not moved to the current point. ("pdf:direct" and "pdf:page" are
 * pdfTeX-compatibility forms that Tectonic's dvipdfmx doesn't draw, so we don't either.)
 * dvipdfmx starts each page with "1 0 0 1 72 720 cm", so its coordinates are relative to the DVI origin (1in, 1in
 * from the top left, y up), under any pdf:btrans transforms around their own points. That is the current CTM
 * moved back by the current point. State changes other than the CTM stay, as dvipdfmx doesn't wrap the code. */
static int pdf_direct(fz_context *ctx, dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim)
{
  float s = dc->scale;
  dvi_state d = *st;
  dvi_set_ctm(&d, fz_pre_translate(dvi_get_ctm(dc, st), -st->registers.h * s, st->registers.v * s));
  bool ok = pdf_code(ctx, dc, &d, cur, lim);
  fz_matrix ctm = st->gs.ctm;
  int h = st->gs.h, v = st->gs.v;
  st->gs = d.gs;
  st->gs.ctm = ctm;
  st->gs.h = h;
  st->gs.v = v;
  st->gs_stack.depth = d.gs_stack.depth;
  return ok;
}

static int
taudot_extra_special(fz_context *ctx, dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim)
{
  static const char q[] = "q", Q[] = "Q";
  while (cur < lim && *cur == ' ') cur++;
  while (lim > cur && lim[-1] == ' ') lim--;
  size_t n = lim - cur;
  if (n == 7 && memcmp(cur, "x:gsave", 7) == 0)
    return pdf_code(ctx, dc, st, q, q + 1);
  if (n == 10 && memcmp(cur, "x:grestore", 10) == 0)
    return pdf_code(ctx, dc, st, Q, Q + 1);
  /* graphicx's \scalebox{sx}[sy] with sx != sy: "x:scale sx sy". TeXpresso's rule takes one factor, so it scaled
     both axes by sx and dropped sy. */
  if (n > 8 && memcmp(cur, "x:scale ", 8) == 0)
  {
    char buf[64];
    size_t len = n - 8;
    if (len < sizeof(buf))
    {
      memcpy(buf, cur + 8, len);
      buf[len] = 0;
      char *e1, *e2;
      float sx = strtof(buf, &e1);
      float sy = e1 != buf ? strtof(e1, &e2) : 0;
      if (e1 != buf && e2 != e1)
      {
        while (*e2 == ' ') e2++;
        if (*e2 == 0)
        {
          st->gs.ctm = fz_concat(fz_scale(sx, sy), st->gs.ctm);
          return 1;
        }
      }
    }
  }
  if (n > 4 && memcmp(cur, "pdf:", 4) == 0)
  {
    cursor_t p = cur + 4;
    while (p < lim && *p == ' ') p++;
    if (lim - p >= 5 && memcmp(p, "bxobj", 5) == 0)
      return form_begin(ctx, dc, st, p + 5, lim);
    if (lim - p >= 5 && memcmp(p, "exobj", 5) == 0)
      return form_end(ctx, dc, st, p + 5, lim);
    if (lim - p >= 5 && memcmp(p, "uxobj", 5) == 0)
      return form_use(ctx, dc, st, p + 5, lim);
    if (lim - p > 4 && memcmp(p, "put ", 4) == 0)
    {
      scan_extgstates(ctx, dc, p + 4, lim);
      scan_pattern_names(ctx, dc, p + 4, lim);
      scan_shadings(ctx, dc, p + 4, lim);
      return -1;
    }
    if (lim - p > 7 && memcmp(p, "stream ", 7) == 0)
      return pattern_stream(ctx, dc, p + 7, lim);
    if (lim - p > 8 && memcmp(p, "literal ", 8) == 0)
    {
      p += 8;
      while (p < lim && *p == ' ') p++;
      if (lim - p >= 6 && memcmp(p, "direct", 6) == 0)
        return pdf_direct(ctx, dc, st, p + 6, lim);
      if (lim - p >= 4 && memcmp(p, "page", 4) == 0)
        return -1;
      return pdf_code(ctx, dc, st, p, lim);
    }
    /* "pdf:content": at the current point, inside q/Q */
    if (lim - p > 8 && memcmp(p, "content ", 8) == 0)
    {
      static const char q[] = "q", Q[] = "Q";
      bool ok = pdf_code(ctx, dc, st, q, q + 1);
      ok = pdf_code(ctx, dc, st, p + 8, lim) && ok;
      return pdf_code(ctx, dc, st, Q, Q + 1) && ok;
    }
  }
  return -1;
}

bool dvi_exec_special(fz_context *ctx, dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim)
{
  cursor_t mar, i, j;

  int extra = taudot_extra_special(ctx, dc, st, cur, lim);
  if (extra >= 0)
    return extra;

  // fprintf(stderr, "special: %.*s\n", (int)(lim - cur), cur);

  for (;;)
  {
    /*!re2c

    " "
    { continue; }

    "landscape"
    { return 1; }

    "pdfcolorstack" ws+ @i nat
                    ws+ "current"
    { return pdfcolorstack_current(ctx, dc, st, pint(i, lim)); }

    "pdfcolorstack" ws+ @i nat
                    ws+ "pop"
    { return colorstack_pop(ctx, dc, st, pint(i, lim)); }

    "pdfcolorstack" ws+ @i nat
                    ws+ "push" ws+ "("
    {
      return colorstack_push(ctx, dc, st, pint(i, lim)) &&
             parse_pdfcolor(ctx, &st->gs.colors, cur, lim);
    }

    "pdfcolorstackinit" ws+ @i nat
                        ws+ "page" ws+ "direct" ws+ "("
    {
      return colorstack_init(ctx, dc, st, pint(i, lim)) &&
             parse_pdfcolor(ctx, &st->gs.colors, cur, lim);
    }

    "color" ws+ "pop"
    { return colorstack_pop(ctx, dc, st, -1); }

    "color" ws+ "push" ws+
    {
      return colorstack_push(ctx, dc, st, -1) &&
             parse_color(ctx, &st->gs.colors, cur, lim);
    }

    "x:"
    {
      struct xform_spec xf = xform_spec();
      cur = parse_xform_or_dim(&xf, cur, lim);
      st->gs.ctm = fz_concat(xf.ctm, st->gs.ctm);
      if (cur < lim)
        return unhandled("pdf x", cur, lim, 0);
      return 1;
    }

    "pdf:" ws*
    { return dvi_exec_pdf(ctx, dc, st, cur, lim); }

    ''
    { return unhandled("special", cur, lim, 0); }

    */
  }
}

bool dvi_init_special(fz_context *ctx, dvi_context *dc, dvi_state *st, cursor_t cur, cursor_t lim)
{
  cursor_t i, f0, f1, mar;

  /*!re2c

  "pdfcolorstackinit" ws+ @i nat
                      ws+ "page" ws+ "direct" ws+ "("
  {
    return colorstack_init(ctx, dc, st, pint(i, lim)) &&
           parse_pdfcolor(ctx, &st->gs.colors, cur, lim);
  }

  ''
  { return 0; }

  */
}

void dvi_prescan_special(cursor_t cur, cursor_t lim, float *width, float *height, bool *landscape)
{
  cursor_t f0, f1, mar;

  // fprintf(stderr, "prescan: %.*s\n", (int)(lim - cur), cur);

  /*!re2c

  "landscape"
  {
    *landscape = 1;
    return;
  }

  "pdf:" ws* "pagesize" ws+ "width" ws+ @f0 dim
                        ws+ "height" ws+ @f1 dim
  {
    *width = pdim(f0, lim);
    *height = pdim(f1, lim);
    return;
  }

  "pdf:" ws* "pagesize" ws+ "default"
  { *width = 612; *height = 792; return; }

  ''
  { return; }

  */
}
