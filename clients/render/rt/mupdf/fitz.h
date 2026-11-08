/* Taudot's drawing runtime: the small part of a "fitz"-style API that TeXpresso's DVI interpreter (dvi/, MIT) and
 * txp-render's verbs call, implemented by Taudot without MuPDF (rt/fitz.c, rt/fonts.c, rt/images.c).
 *
 * Copyright (c) 2026 the Taudot authors. MIT License (rt/LICENSE).
 *
 * Written from how the interpreter uses these names, not from MuPDF's source: MuPDF is AGPL and none of its code is
 * here. Only what the interpreter and our verbs call exists. The names stay as the interpreter spells them so that
 * TeXpresso's code builds unchanged; the header lives at <mupdf/fitz.h> for the same reason.
 *
 * Differences from the library the interpreter was written against, on purpose:
 *  - no colour management: Gray, RGB and CMYK only (CMYK through Core Graphics' generic profile);
 *  - no PDF interpreter: an included PDF page is one figure op (fz_fill_figure), drawn by Core Graphics;
 *  - no rasteriser: pages are drawn from the display list by TaudotRender (swift/);
 *  - fonts through FreeType (fonts/taudot_font.h), images through ImageIO.
 * Single-threaded. */

#ifndef TAUDOT_RT_FITZ_H
#define TAUDOT_RT_FITZ_H

#include <math.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FZ_VERSION_MAJOR 1
#define FZ_VERSION_MINOR 99
#define FZ_VERSION "taudot-rt"

#ifndef nil
#define nil ((void *)0)
#endif

/* ---- context, memory, errors ------------------------------------------------------------------------------------ */

typedef struct fz_context fz_context;

enum { FZ_ERROR_NONE = 0, FZ_ERROR_GENERIC = 1, FZ_ERROR_SYSTEM = 2, FZ_ERROR_FORMAT = 3, FZ_ERROR_ARGUMENT = 4,
       FZ_ERROR_LIMIT = 5, FZ_ERROR_UNSUPPORTED = 6, FZ_ERROR_ABORT = 7, FZ_ERROR_MEMORY = 8 };

#define FZ_TRY_DEPTH 256
typedef struct
{
  jmp_buf buf;
  int state; /* 0 in the try body, 1 in always */
  int errored;
} fz_try_frame;

struct fz_context
{
  fz_try_frame frames[FZ_TRY_DEPTH];
  int depth;
  int code;
  char message[256];
};

fz_context *fz_new_context_imp(void);
#define fz_new_context(alloc, locks, store) fz_new_context_imp()
void fz_drop_context(fz_context *ctx);
void fz_register_document_handlers(fz_context *ctx);

/* try / always / catch, with setjmp. As with any setjmp scheme: never return or goto out of a try body. */
jmp_buf *fz_push_try_(fz_context *ctx);
int fz_do_always_(fz_context *ctx);
int fz_do_catch_(fz_context *ctx);
#define fz_try(ctx) if (setjmp(*fz_push_try_(ctx)) == 0) do
#define fz_always(ctx) while (0); if (fz_do_always_(ctx)) do
#define fz_catch(ctx) while (0); if (fz_do_catch_(ctx))

void fz_var_imp(void *);
#define fz_var(var) fz_var_imp((void *)&(var))

#if defined(__GNUC__)
#define FZ_NORETURN __attribute__((noreturn))
#define FZ_PRINTFLIKE(f, a) __attribute__((format(printf, f, a)))
#else
#define FZ_NORETURN
#define FZ_PRINTFLIKE(f, a)
#endif

FZ_NORETURN void fz_throw(fz_context *ctx, int code, const char *fmt, ...) FZ_PRINTFLIKE(3, 4);
FZ_NORETURN void fz_rethrow(fz_context *ctx);
const char *fz_caught_message(fz_context *ctx);
int fz_caught(fz_context *ctx);
void fz_warn(fz_context *ctx, const char *fmt, ...) FZ_PRINTFLIKE(2, 3);

void *fz_malloc(fz_context *ctx, size_t size);
void *fz_calloc(fz_context *ctx, size_t count, size_t size);
void *fz_realloc(fz_context *ctx, void *p, size_t size);
void *fz_malloc_no_throw(fz_context *ctx, size_t size);
void fz_free(fz_context *ctx, void *p);
char *fz_strdup(fz_context *ctx, const char *s);
#define fz_malloc_struct(ctx, T) ((T *)fz_calloc(ctx, 1, sizeof(T)))
#define fz_malloc_array(ctx, n, T) ((T *)fz_malloc(ctx, (size_t)(n) * sizeof(T)))
#define fz_malloc_struct_array(ctx, n, T) ((T *)fz_calloc(ctx, (n), sizeof(T)))
#define fz_realloc_array(ctx, p, n, T) ((T *)fz_realloc(ctx, p, (size_t)(n) * sizeof(T)))
#define Memento_label(p, s) (p)

const void *fz_memmem(const void *hay, size_t hlen, const void *needle, size_t nlen);

static inline int fz_maxi(int a, int b) { return a > b ? a : b; }
static inline int fz_mini(int a, int b) { return a < b ? a : b; }
static inline float fz_max(float a, float b) { return a > b ? a : b; }
static inline float fz_min(float a, float b) { return a < b ? a : b; }
static inline float fz_clamp(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }
static inline int fz_clampi(int x, int lo, int hi) { return x < lo ? lo : x > hi ? hi : x; }
static inline double fz_clampd(double x, double lo, double hi) { return x < lo ? lo : x > hi ? hi : x; }

/* ---- geometry ----------------------------------------------------------------------------------------------------- */

typedef struct { float x, y; } fz_point;
typedef struct { float x0, y0, x1, y1; } fz_rect;
typedef struct { int x0, y0, x1, y1; } fz_irect;
/* (x, y) → (a·x + c·y + e, b·x + d·y + f) */
typedef struct { float a, b, c, d, e, f; } fz_matrix;

#define FZ_MIN_INF_RECT ((int)0x80000000)
#define FZ_MAX_INF_RECT ((int)0x7fffff80)

extern const fz_rect fz_infinite_rect, fz_empty_rect, fz_unit_rect;
extern const fz_irect fz_infinite_irect, fz_empty_irect;
extern const fz_matrix fz_identity;

static inline fz_point fz_make_point(float x, float y) { fz_point p = {x, y}; return p; }
static inline fz_rect fz_make_rect(float x0, float y0, float x1, float y1) { fz_rect r = {x0, y0, x1, y1}; return r; }
static inline fz_irect fz_make_irect(int x0, int y0, int x1, int y1) { fz_irect r = {x0, y0, x1, y1}; return r; }
static inline fz_matrix fz_make_matrix(float a, float b, float c, float d, float e, float f)
{ fz_matrix m = {a, b, c, d, e, f}; return m; }

int fz_is_empty_rect(fz_rect r);
int fz_is_infinite_rect(fz_rect r);
int fz_is_empty_irect(fz_irect r);
fz_rect fz_union_rect(fz_rect a, fz_rect b);
fz_rect fz_intersect_rect(fz_rect a, fz_rect b);
fz_irect fz_intersect_irect(fz_irect a, fz_irect b);
fz_rect fz_include_point_in_rect(fz_rect r, fz_point p);
fz_rect fz_rect_from_irect(fz_irect r);
fz_irect fz_round_rect(fz_rect r);
fz_irect fz_irect_from_rect(fz_rect r);
int fz_is_point_inside_irect(int x, int y, fz_irect r);
fz_rect fz_expand_rect(fz_rect r, float e);
static inline unsigned fz_irect_width(fz_irect r) { return r.x0 < r.x1 ? (unsigned)(r.x1 - r.x0) : 0; }
static inline unsigned fz_irect_height(fz_irect r) { return r.y0 < r.y1 ? (unsigned)(r.y1 - r.y0) : 0; }

fz_matrix fz_concat(fz_matrix left, fz_matrix right); /* left, then right */
fz_matrix fz_scale(float sx, float sy);
fz_matrix fz_translate(float tx, float ty);
fz_matrix fz_rotate(float degrees);
fz_matrix fz_pre_scale(fz_matrix m, float sx, float sy);
fz_matrix fz_pre_translate(fz_matrix m, float tx, float ty);
fz_matrix fz_pre_rotate(fz_matrix m, float degrees);
fz_matrix fz_invert_matrix(fz_matrix m);
float fz_matrix_expansion(fz_matrix m);
fz_point fz_transform_point(fz_point p, fz_matrix m);
fz_point fz_transform_point_xy(float x, float y, fz_matrix m);
fz_point fz_transform_vector(fz_point v, fz_matrix m);
fz_rect fz_transform_rect(fz_rect r, fz_matrix m);

/* ---- buffers and streams ------------------------------------------------------------------------------------------ */

typedef struct fz_buffer
{
  int refs;
  unsigned char *data;
  size_t cap, len;
  int unused_bits;
  int shared;
} fz_buffer;

fz_buffer *fz_new_buffer(fz_context *ctx, size_t capacity);
fz_buffer *fz_new_buffer_from_copied_data(fz_context *ctx, const unsigned char *data, size_t size);
fz_buffer *fz_keep_buffer(fz_context *ctx, fz_buffer *b);
void fz_drop_buffer(fz_context *ctx, fz_buffer *b);
void fz_resize_buffer(fz_context *ctx, fz_buffer *b, size_t capacity);
void fz_grow_buffer(fz_context *ctx, fz_buffer *b);
void fz_trim_buffer(fz_context *ctx, fz_buffer *b);
void fz_clear_buffer(fz_context *ctx, fz_buffer *b);
void fz_terminate_buffer(fz_context *ctx, fz_buffer *b);
size_t fz_buffer_storage(fz_context *ctx, fz_buffer *b, unsigned char **data);
void fz_append_data(fz_context *ctx, fz_buffer *b, const void *data, size_t len);
void fz_append_string(fz_context *ctx, fz_buffer *b, const char *s);
void fz_append_byte(fz_context *ctx, fz_buffer *b, int c);
void fz_append_printf(fz_context *ctx, fz_buffer *b, const char *fmt, ...) FZ_PRINTFLIKE(3, 4);
void fz_append_vprintf(fz_context *ctx, fz_buffer *b, const char *fmt, va_list ap);
fz_buffer *fz_read_file(fz_context *ctx, const char *path);

/* A stream over a file or memory: only reading forward. */
typedef struct fz_stream fz_stream;
fz_stream *fz_open_file(fz_context *ctx, const char *path);
fz_stream *fz_open_memory(fz_context *ctx, const unsigned char *data, size_t len);
fz_stream *fz_open_buffer(fz_context *ctx, fz_buffer *b);
/* Reads from chain, appending everything read to buf. */
fz_stream *fz_open_leecher(fz_context *ctx, fz_stream *chain, fz_buffer *buf);
fz_stream *fz_keep_stream(fz_context *ctx, fz_stream *s);
void fz_drop_stream(fz_context *ctx, fz_stream *s);
size_t fz_read(fz_context *ctx, fz_stream *s, unsigned char *data, size_t len);
size_t fz_skip(fz_context *ctx, fz_stream *s, size_t len);
fz_buffer *fz_read_all(fz_context *ctx, fz_stream *s, size_t initial);
fz_buffer *fz_read_best(fz_context *ctx, fz_stream *s, size_t initial, int *truncated, size_t worst_case);
int fz_read_byte(fz_context *ctx, fz_stream *s);
int fz_peek_byte(fz_context *ctx, fz_stream *s);
int64_t fz_tell(fz_context *ctx, fz_stream *s);
void fz_seek(fz_context *ctx, fz_stream *s, int64_t offset, int whence);
/* The path the stream was opened from (fz_open_file), else NULL. */
const char *fz_stream_filename(fz_stream *s);

/* ---- colour ------------------------------------------------------------------------------------------------------- */

typedef struct fz_colorspace
{
  int refs; /* the device spaces are static */
  int n;
  const char *name;
} fz_colorspace;

typedef struct { uint8_t ri, bp, op, opm; } fz_color_params;
extern const fz_color_params fz_default_color_params;

fz_colorspace *fz_device_gray(fz_context *ctx);
fz_colorspace *fz_device_rgb(fz_context *ctx);
fz_colorspace *fz_device_cmyk(fz_context *ctx);
fz_colorspace *fz_keep_colorspace(fz_context *ctx, fz_colorspace *cs);
void fz_drop_colorspace(fz_context *ctx, fz_colorspace *cs);
int fz_colorspace_n(fz_context *ctx, fz_colorspace *cs);
const char *fz_colorspace_name(fz_context *ctx, fz_colorspace *cs);
/* Any of Gray, RGB, CMYK to any of them. dst gets fz_colorspace_n(dst) values. */
void fz_convert_color(fz_context *ctx, fz_colorspace *src, const float *sv, fz_colorspace *dst, float *dv,
                      fz_colorspace *prf, fz_color_params params);

enum { FZ_BLEND_NORMAL = 0, FZ_BLEND_MULTIPLY, FZ_BLEND_SCREEN, FZ_BLEND_OVERLAY, FZ_BLEND_DARKEN, FZ_BLEND_LIGHTEN,
       FZ_BLEND_COLOR_DODGE, FZ_BLEND_COLOR_BURN, FZ_BLEND_HARD_LIGHT, FZ_BLEND_SOFT_LIGHT, FZ_BLEND_DIFFERENCE,
       FZ_BLEND_EXCLUSION, FZ_BLEND_HUE, FZ_BLEND_SATURATION, FZ_BLEND_COLOR, FZ_BLEND_LUMINOSITY };

/* ---- paths and strokes ------------------------------------------------------------------------------------------ */

typedef struct fz_path fz_path; /* M L Q C Z commands and their coordinates */

fz_path *fz_new_path(fz_context *ctx);
fz_path *fz_keep_path(fz_context *ctx, const fz_path *p);
void fz_drop_path(fz_context *ctx, const fz_path *p);
fz_path *fz_clone_path(fz_context *ctx, const fz_path *p);
void fz_moveto(fz_context *ctx, fz_path *p, float x, float y);
void fz_lineto(fz_context *ctx, fz_path *p, float x, float y);
void fz_curveto(fz_context *ctx, fz_path *p, float x1, float y1, float x2, float y2, float x3, float y3);
void fz_curvetov(fz_context *ctx, fz_path *p, float x2, float y2, float x3, float y3);
void fz_curvetoy(fz_context *ctx, fz_path *p, float x1, float y1, float x3, float y3);
void fz_quadto(fz_context *ctx, fz_path *p, float x1, float y1, float x2, float y2);
void fz_closepath(fz_context *ctx, fz_path *p);
void fz_rectto(fz_context *ctx, fz_path *p, float x0, float y0, float x1, float y1);
fz_point fz_currentpoint(fz_context *ctx, fz_path *p);
void fz_transform_path(fz_context *ctx, fz_path *p, fz_matrix m);

typedef struct
{
  void (*moveto)(fz_context *ctx, void *arg, float x, float y);
  void (*lineto)(fz_context *ctx, void *arg, float x, float y);
  void (*curveto)(fz_context *ctx, void *arg, float x1, float y1, float x2, float y2, float x3, float y3);
  void (*closepath)(fz_context *ctx, void *arg);
  void (*quadto)(fz_context *ctx, void *arg, float x1, float y1, float x2, float y2);
  void (*curvetov)(fz_context *ctx, void *arg, float x2, float y2, float x3, float y3);
  void (*curvetoy)(fz_context *ctx, void *arg, float x1, float y1, float x3, float y3);
  void (*rectto)(fz_context *ctx, void *arg, float x1, float y1, float x2, float y2);
} fz_path_walker;
void fz_walk_path(fz_context *ctx, const fz_path *p, const fz_path_walker *w, void *arg);

typedef enum { FZ_LINECAP_BUTT = 0, FZ_LINECAP_ROUND = 1, FZ_LINECAP_SQUARE = 2, FZ_LINECAP_TRIANGLE = 3 } fz_linecap;
typedef enum { FZ_LINEJOIN_MITER = 0, FZ_LINEJOIN_ROUND = 1, FZ_LINEJOIN_BEVEL = 2, FZ_LINEJOIN_MITER_XPS = 3 }
  fz_linejoin;

typedef struct
{
  int refs; /* -2: static */
  int start_cap, dash_cap, end_cap;
  int linejoin;
  float linewidth;
  float miterlimit;
  float dash_phase;
  int dash_len;
  float dash_list[];
} fz_stroke_state;

extern const fz_stroke_state fz_default_stroke_state;
fz_stroke_state *fz_new_stroke_state(fz_context *ctx);
fz_stroke_state *fz_new_stroke_state_with_dash_len(fz_context *ctx, int len);
fz_stroke_state *fz_keep_stroke_state(fz_context *ctx, const fz_stroke_state *s);
void fz_drop_stroke_state(fz_context *ctx, const fz_stroke_state *s);
fz_stroke_state *fz_clone_stroke_state(fz_context *ctx, const fz_stroke_state *s);

/* Points of the path (control points included) through ctm, grown by half the stroke's width when stroke is given. */
fz_rect fz_bound_path(fz_context *ctx, const fz_path *p, const fz_stroke_state *stroke, fz_matrix ctm);

/* ---- fonts and text ------------------------------------------------------------------------------------------------ */

struct tf_font;
typedef struct fz_font
{
  int refs;
  struct tf_font *tf;
  fz_buffer *buffer; /* the font file */
  int index;         /* face index in it */
  char name[32];
  uint64_t hash;     /* of the file's bytes and the index, 0 until asked (fz_hash_display_list) */
} fz_font;

fz_font *fz_new_font_from_buffer(fz_context *ctx, const char *name, fz_buffer *buffer, int index, int use_glyph_bbox);
fz_font *fz_keep_font(fz_context *ctx, fz_font *f);
void fz_drop_font(fz_context *ctx, fz_font *f);
const char *fz_font_name(fz_context *ctx, fz_font *f);
float fz_font_ascender(fz_context *ctx, fz_font *f);
float fz_font_descender(fz_context *ctx, fz_font *f);
/* Not exposed: the face belongs to the font loader, which already selects the charmap (fonts/taudot_font.h). */
static inline void *fz_font_ft_face(fz_context *ctx, fz_font *f) { (void)ctx; (void)f; return NULL; }
int fz_encode_character(fz_context *ctx, fz_font *f, int unicode);
int fz_encode_character_by_glyph_name(fz_context *ctx, fz_font *f, const char *name);
float fz_advance_glyph(fz_context *ctx, fz_font *f, int gid, int wmode);
/* em space, y up, through ctm. NULL for glyphs without an outline. */
fz_path *fz_outline_glyph(fz_context *ctx, fz_font *f, int gid, fz_matrix ctm);
void fz_get_glyph_name(fz_context *ctx, fz_font *f, int gid, char *buf, int size);
int fz_unicode_from_glyph_name(const char *name);
/* The Adobe Glyph List and TeX's additions, read by the caller (from the TeX bundle). */
void fz_set_glyph_lists(const char *agl, size_t agl_len, const char *tex, size_t tex_len);

typedef enum { FZ_BIDI_LTR = 0, FZ_BIDI_RTL = 1, FZ_BIDI_NEUTRAL = 5 } fz_bidi_direction;
typedef enum { FZ_LANG_UNSET = 0 } fz_text_language;

typedef struct { float x, y; int gid; int ucs; } fz_text_item;

typedef struct fz_text_span
{
  fz_font *font;
  fz_matrix trm; /* the glyphs' matrix, without the translation (each item has its own) */
  int wmode;
  int len, cap;
  fz_text_item *items;
  struct fz_text_span *next;
} fz_text_span;

typedef struct fz_text
{
  int refs;
  fz_text_span *head, *tail;
} fz_text;

fz_text *fz_new_text(fz_context *ctx);
fz_text *fz_keep_text(fz_context *ctx, const fz_text *t);
void fz_drop_text(fz_context *ctx, const fz_text *t);
void fz_show_glyph(fz_context *ctx, fz_text *text, fz_font *font, fz_matrix trm, int gid, int ucs, int wmode,
                   int bidi_level, fz_bidi_direction markup_dir, fz_text_language language);
/* Each glyph's advance box (font descender to ascender) through its matrix and ctm. */
fz_rect fz_bound_text(fz_context *ctx, const fz_text *text, const fz_stroke_state *stroke, fz_matrix ctm);

/* ---- images ------------------------------------------------------------------------------------------------------- */

enum { FZ_IMAGE_UNKNOWN = 0, FZ_IMAGE_PNG = 1, FZ_IMAGE_JPEG = 2, FZ_IMAGE_OTHER = 3 };

typedef struct fz_image
{
  int refs;
  int w, h;
  int n;            /* colour components: 1 grey, 3 RGB, 4 CMYK */
  int alpha;        /* the file has an alpha channel */
  int imagemask;    /* always 0 for file images */
  int type;         /* FZ_IMAGE_* */
  int xres, yres;
  fz_colorspace *colorspace;
  fz_buffer *buffer; /* the file's bytes */
} fz_image;

/* PNG, JPEG, and anything else ImageIO reads (decoded when drawn). */
fz_image *fz_new_image_from_buffer(fz_context *ctx, fz_buffer *buffer);
fz_image *fz_new_image_from_file(fz_context *ctx, const char *path);
fz_image *fz_keep_image(fz_context *ctx, fz_image *img);
void fz_drop_image(fz_context *ctx, fz_image *img);
void fz_image_resolution(fz_image *img, int *xres, int *yres);
/* Decoded to 8-bit RGBA, not premultiplied (malloc'd, w*h*4). NULL if ImageIO can't. */
unsigned char *fz_image_rgba(fz_context *ctx, fz_image *img, int *w, int *h);

/* ---- shadings ----------------------------------------------------------------------------------------------------- */

enum { FZ_FUNCTION_BASED = 1, FZ_LINEAR = 2, FZ_RADIAL = 3, FZ_MESH_TYPE4 = 4 };

typedef struct fz_shade
{
  int refs;
  int type;
  fz_colorspace *colorspace;
  fz_matrix matrix; /* shading space → the space it is drawn in */
  fz_rect bbox;     /* shading space; infinite: none */
  int function_stride;
  float *function; /* 256 samples of (colour..., alpha) */
  union { struct { int extend[2]; float coords[2][3]; } l_or_r; } u;
} fz_shade;

/* the interpreter allocates shades itself and sets their count with this */
#define FZ_INIT_STORABLE(s, r, drop) ((s)->refs = (r))
void fz_drop_shade_imp(fz_context *ctx, void *s);
fz_shade *fz_keep_shade(fz_context *ctx, fz_shade *s);
void fz_drop_shade(fz_context *ctx, fz_shade *s);
fz_rect fz_bound_shade(fz_context *ctx, fz_shade *s, fz_matrix ctm);

typedef struct fz_function fz_function; /* soft-mask transfer functions: never made here */

/* ---- figures: one page of an included PDF ---------------------------------------------------------------------- */

typedef struct fz_figure
{
  int refs;
  char *path; /* the PDF file */
  int page;   /* 1-based */
  fz_rect box; /* the page's crop box (∩ media box), PDF user space */
  int rotate;  /* /Rotate, degrees */
} fz_figure;

/* Opens page `page` (1-based) of a PDF with Core Graphics, for its boxes. NULL if it can't. */
fz_figure *fz_new_figure(fz_context *ctx, const char *path, int page);
fz_figure *fz_keep_figure(fz_context *ctx, fz_figure *f);
void fz_drop_figure(fz_context *ctx, fz_figure *f);
/* The page's matrix to a y-down frame with the (rotated) box at the origin, as the interpreter expects. */
fz_matrix fz_figure_page_ctm(fz_figure *f);
int fz_figure_page_count(fz_context *ctx, const char *path);

/* ---- devices ------------------------------------------------------------------------------------------------------ */

typedef struct fz_device fz_device;
typedef struct fz_cookie fz_cookie;

struct fz_device
{
  int refs;
  int hints, flags;
  void (*close_device)(fz_context *, fz_device *);
  void (*drop_device)(fz_context *, fz_device *);

  void (*fill_path)(fz_context *, fz_device *, const fz_path *, int even_odd, fz_matrix, fz_colorspace *,
                    const float *color, float alpha, fz_color_params);
  void (*stroke_path)(fz_context *, fz_device *, const fz_path *, const fz_stroke_state *, fz_matrix,
                      fz_colorspace *, const float *color, float alpha, fz_color_params);
  void (*clip_path)(fz_context *, fz_device *, const fz_path *, int even_odd, fz_matrix, fz_rect scissor);
  void (*clip_stroke_path)(fz_context *, fz_device *, const fz_path *, const fz_stroke_state *, fz_matrix,
                           fz_rect scissor);

  void (*fill_text)(fz_context *, fz_device *, const fz_text *, fz_matrix, fz_colorspace *, const float *color,
                    float alpha, fz_color_params);
  void (*stroke_text)(fz_context *, fz_device *, const fz_text *, const fz_stroke_state *, fz_matrix,
                      fz_colorspace *, const float *color, float alpha, fz_color_params);
  void (*clip_text)(fz_context *, fz_device *, const fz_text *, fz_matrix, fz_rect scissor);
  void (*clip_stroke_text)(fz_context *, fz_device *, const fz_text *, const fz_stroke_state *, fz_matrix,
                           fz_rect scissor);
  void (*ignore_text)(fz_context *, fz_device *, const fz_text *, fz_matrix);

  void (*fill_shade)(fz_context *, fz_device *, fz_shade *, fz_matrix, float alpha, fz_color_params);
  void (*fill_image)(fz_context *, fz_device *, fz_image *, fz_matrix, float alpha, fz_color_params);
  void (*fill_image_mask)(fz_context *, fz_device *, fz_image *, fz_matrix, fz_colorspace *, const float *color,
                          float alpha, fz_color_params);
  void (*clip_image_mask)(fz_context *, fz_device *, fz_image *, fz_matrix, fz_rect scissor);

  void (*pop_clip)(fz_context *, fz_device *);

  void (*begin_mask)(fz_context *, fz_device *, fz_rect area, int luminosity, fz_colorspace *, const float *bc,
                     fz_color_params);
  void (*end_mask)(fz_context *, fz_device *, fz_function *);
  void (*begin_group)(fz_context *, fz_device *, fz_rect area, fz_colorspace *, int isolated, int knockout,
                      int blendmode, float alpha);
  void (*end_group)(fz_context *, fz_device *);

  int (*begin_tile)(fz_context *, fz_device *, fz_rect area, fz_rect view, float xstep, float ystep, fz_matrix,
                    int id, int doc_id);
  void (*end_tile)(fz_context *, fz_device *);

  /* Taudot: a page of an included PDF, drawn whole under ctm (fz_figure_page_ctm already applied by the caller). */
  void (*fill_figure)(fz_context *, fz_device *, fz_figure *, fz_matrix);
};

fz_device *fz_new_device_of_size(fz_context *ctx, int size);
#define fz_new_derived_device(ctx, T) ((T *)fz_new_device_of_size(ctx, sizeof(T)))
fz_device *fz_keep_device(fz_context *ctx, fz_device *dev);
void fz_close_device(fz_context *ctx, fz_device *dev);
void fz_drop_device(fz_context *ctx, fz_device *dev);

void fz_fill_path(fz_context *ctx, fz_device *dev, const fz_path *path, int even_odd, fz_matrix ctm,
                  fz_colorspace *cs, const float *color, float alpha, fz_color_params cp);
void fz_stroke_path(fz_context *ctx, fz_device *dev, const fz_path *path, const fz_stroke_state *stroke,
                    fz_matrix ctm, fz_colorspace *cs, const float *color, float alpha, fz_color_params cp);
void fz_clip_path(fz_context *ctx, fz_device *dev, const fz_path *path, int even_odd, fz_matrix ctm, fz_rect scissor);
void fz_clip_stroke_path(fz_context *ctx, fz_device *dev, const fz_path *path, const fz_stroke_state *stroke,
                         fz_matrix ctm, fz_rect scissor);
void fz_fill_text(fz_context *ctx, fz_device *dev, const fz_text *text, fz_matrix ctm, fz_colorspace *cs,
                  const float *color, float alpha, fz_color_params cp);
void fz_stroke_text(fz_context *ctx, fz_device *dev, const fz_text *text, const fz_stroke_state *stroke,
                    fz_matrix ctm, fz_colorspace *cs, const float *color, float alpha, fz_color_params cp);
void fz_clip_text(fz_context *ctx, fz_device *dev, const fz_text *text, fz_matrix ctm, fz_rect scissor);
void fz_clip_stroke_text(fz_context *ctx, fz_device *dev, const fz_text *text, const fz_stroke_state *stroke,
                         fz_matrix ctm, fz_rect scissor);
void fz_ignore_text(fz_context *ctx, fz_device *dev, const fz_text *text, fz_matrix ctm);
void fz_fill_shade(fz_context *ctx, fz_device *dev, fz_shade *shade, fz_matrix ctm, float alpha, fz_color_params cp);
void fz_fill_image(fz_context *ctx, fz_device *dev, fz_image *image, fz_matrix ctm, float alpha, fz_color_params cp);
void fz_fill_image_mask(fz_context *ctx, fz_device *dev, fz_image *image, fz_matrix ctm, fz_colorspace *cs,
                        const float *color, float alpha, fz_color_params cp);
void fz_clip_image_mask(fz_context *ctx, fz_device *dev, fz_image *image, fz_matrix ctm, fz_rect scissor);
void fz_pop_clip(fz_context *ctx, fz_device *dev);
void fz_begin_mask(fz_context *ctx, fz_device *dev, fz_rect area, int luminosity, fz_colorspace *cs, const float *bc,
                   fz_color_params cp);
void fz_end_mask(fz_context *ctx, fz_device *dev);
void fz_begin_group(fz_context *ctx, fz_device *dev, fz_rect area, fz_colorspace *cs, int isolated, int knockout,
                    int blendmode, float alpha);
void fz_end_group(fz_context *ctx, fz_device *dev);
int fz_begin_tile_id(fz_context *ctx, fz_device *dev, fz_rect area, fz_rect view, float xstep, float ystep,
                     fz_matrix ctm, int id);
void fz_begin_tile(fz_context *ctx, fz_device *dev, fz_rect area, fz_rect view, float xstep, float ystep,
                   fz_matrix ctm);
void fz_end_tile(fz_context *ctx, fz_device *dev);
void fz_fill_figure(fz_context *ctx, fz_device *dev, fz_figure *fig, fz_matrix ctm);

/* ---- display lists: devices calls recorded, replayed under a matrix ------------------------------------------- */

typedef struct fz_display_list fz_display_list;
fz_display_list *fz_new_display_list(fz_context *ctx, fz_rect mediabox);
fz_device *fz_new_list_device(fz_context *ctx, fz_display_list *list);
fz_display_list *fz_keep_display_list(fz_context *ctx, fz_display_list *list);
void fz_drop_display_list(fz_context *ctx, fz_display_list *list);
/* The rect the list was made with (its page box). */
fz_rect fz_bound_display_list(fz_context *ctx, fz_display_list *list);
void fz_run_display_list(fz_context *ctx, fz_display_list *list, fz_device *dev, fz_matrix ctm, fz_rect scissor,
                         fz_cookie *cookie);
/* A hash of everything the list draws (ops, geometry, colours, glyphs and the fonts' bytes): equal pages hash equal. */
uint64_t fz_hash_display_list(fz_context *ctx, fz_display_list *list);

#endif
