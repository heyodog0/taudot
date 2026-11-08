/* Taudot's drawing runtime: errors, memory, geometry, buffers, streams, paths, text, devices and display lists.
 * Copyright (c) 2026 the Taudot authors. MIT License (rt/LICENSE). See mupdf/fitz.h. */

#include "mupdf/fitz.h"

#include <errno.h>
#include <float.h>

/* ---- context and errors ------------------------------------------------------------------------------------------ */

fz_context *fz_new_context_imp(void)
{
  fz_context *ctx = calloc(1, sizeof *ctx);
  if (!ctx) abort();
  return ctx;
}

void fz_drop_context(fz_context *ctx) { free(ctx); }
void fz_register_document_handlers(fz_context *ctx) { (void)ctx; }
void fz_var_imp(void *p) { (void)p; }

jmp_buf *fz_push_try_(fz_context *ctx)
{
  if (ctx->depth >= FZ_TRY_DEPTH)
  {
    fprintf(stderr, "taudot-rt: try blocks nested too deep\n");
    abort();
  }
  fz_try_frame *f = &ctx->frames[ctx->depth++];
  f->state = 0;
  f->errored = 0;
  return &f->buf;
}

int fz_do_always_(fz_context *ctx)
{
  ctx->frames[ctx->depth - 1].state = 1;
  return 1;
}

int fz_do_catch_(fz_context *ctx)
{
  fz_try_frame *f = &ctx->frames[--ctx->depth];
  return f->errored;
}

static FZ_NORETURN void throw_now(fz_context *ctx)
{
  /* frames whose always block is running are finished: the error goes past them */
  while (ctx->depth > 0 && ctx->frames[ctx->depth - 1].state == 1) ctx->depth--;
  if (ctx->depth == 0)
  {
    fprintf(stderr, "taudot-rt: uncaught error: %s\n", ctx->message);
    abort();
  }
  fz_try_frame *f = &ctx->frames[ctx->depth - 1];
  f->errored = 1;
  f->state = 1; /* the always block runs next */
  longjmp(f->buf, 1);
}

void fz_throw(fz_context *ctx, int code, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(ctx->message, sizeof ctx->message, fmt, ap);
  va_end(ap);
  ctx->code = code;
  throw_now(ctx);
}

void fz_rethrow(fz_context *ctx) { throw_now(ctx); }
const char *fz_caught_message(fz_context *ctx) { return ctx->message; }
int fz_caught(fz_context *ctx) { return ctx->code; }

void fz_warn(fz_context *ctx, const char *fmt, ...)
{
  (void)ctx;
  va_list ap;
  va_start(ap, fmt);
  fputs("warning: ", stderr);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
}

/* ---- memory ------------------------------------------------------------------------------------------------------- */

void *fz_malloc(fz_context *ctx, size_t size)
{
  if (size == 0) size = 1;
  void *p = malloc(size);
  if (!p) fz_throw(ctx, FZ_ERROR_MEMORY, "out of memory (%zu bytes)", size);
  return p;
}

void *fz_malloc_no_throw(fz_context *ctx, size_t size) { (void)ctx; return malloc(size ? size : 1); }

void *fz_calloc(fz_context *ctx, size_t count, size_t size)
{
  if (count == 0 || size == 0) count = size = 1;
  if (count > SIZE_MAX / size) fz_throw(ctx, FZ_ERROR_MEMORY, "calloc overflow");
  void *p = calloc(count, size);
  if (!p) fz_throw(ctx, FZ_ERROR_MEMORY, "out of memory (%zu × %zu bytes)", count, size);
  return p;
}

void *fz_realloc(fz_context *ctx, void *p, size_t size)
{
  if (size == 0) { free(p); return NULL; }
  void *q = realloc(p, size);
  if (!q) fz_throw(ctx, FZ_ERROR_MEMORY, "out of memory (%zu bytes)", size);
  return q;
}

void fz_free(fz_context *ctx, void *p) { (void)ctx; free(p); }

char *fz_strdup(fz_context *ctx, const char *s)
{
  size_t n = strlen(s) + 1;
  char *d = fz_malloc(ctx, n);
  memcpy(d, s, n);
  return d;
}

const void *fz_memmem(const void *hay, size_t hlen, const void *needle, size_t nlen)
{
  if (nlen == 0) return hay;
  if (nlen > hlen) return NULL;
  const unsigned char *h = hay, *n = needle;
  for (size_t i = 0; i + nlen <= hlen; i++)
    if (h[i] == n[0] && memcmp(h + i, n, nlen) == 0) return h + i;
  return NULL;
}

/* ---- geometry ----------------------------------------------------------------------------------------------------- */

const fz_rect fz_infinite_rect = {FZ_MIN_INF_RECT, FZ_MIN_INF_RECT, FZ_MAX_INF_RECT, FZ_MAX_INF_RECT};
const fz_rect fz_empty_rect = {FZ_MAX_INF_RECT, FZ_MAX_INF_RECT, FZ_MIN_INF_RECT, FZ_MIN_INF_RECT};
const fz_rect fz_unit_rect = {0, 0, 1, 1};
const fz_irect fz_infinite_irect = {FZ_MIN_INF_RECT, FZ_MIN_INF_RECT, FZ_MAX_INF_RECT, FZ_MAX_INF_RECT};
const fz_irect fz_empty_irect = {FZ_MAX_INF_RECT, FZ_MAX_INF_RECT, FZ_MIN_INF_RECT, FZ_MIN_INF_RECT};
const fz_matrix fz_identity = {1, 0, 0, 1, 0, 0};

int fz_is_empty_rect(fz_rect r) { return r.x0 >= r.x1 || r.y0 >= r.y1; }
int fz_is_infinite_rect(fz_rect r) { return r.x0 == FZ_MIN_INF_RECT && r.x1 == FZ_MAX_INF_RECT && r.y0 == FZ_MIN_INF_RECT && r.y1 == FZ_MAX_INF_RECT; }
int fz_is_empty_irect(fz_irect r) { return r.x0 >= r.x1 || r.y0 >= r.y1; }

fz_rect fz_union_rect(fz_rect a, fz_rect b)
{
  if (fz_is_empty_rect(b)) return a;
  if (fz_is_empty_rect(a)) return b;
  if (fz_is_infinite_rect(a)) return a;
  if (fz_is_infinite_rect(b)) return b;
  return fz_make_rect(fminf(a.x0, b.x0), fminf(a.y0, b.y0), fmaxf(a.x1, b.x1), fmaxf(a.y1, b.y1));
}

fz_rect fz_intersect_rect(fz_rect a, fz_rect b)
{
  if (fz_is_infinite_rect(b)) return a;
  if (fz_is_infinite_rect(a)) return b;
  if (fz_is_empty_rect(a)) return fz_empty_rect;
  if (fz_is_empty_rect(b)) return fz_empty_rect;
  fz_rect r = fz_make_rect(fmaxf(a.x0, b.x0), fmaxf(a.y0, b.y0), fminf(a.x1, b.x1), fminf(a.y1, b.y1));
  return fz_is_empty_rect(r) ? fz_empty_rect : r;
}

fz_irect fz_intersect_irect(fz_irect a, fz_irect b)
{
  fz_irect r = {a.x0 > b.x0 ? a.x0 : b.x0, a.y0 > b.y0 ? a.y0 : b.y0, a.x1 < b.x1 ? a.x1 : b.x1,
                a.y1 < b.y1 ? a.y1 : b.y1};
  return fz_is_empty_irect(r) ? fz_empty_irect : r;
}

fz_rect fz_include_point_in_rect(fz_rect r, fz_point p)
{
  if (fz_is_infinite_rect(r)) return r;
  if (fz_is_empty_rect(r) && !(r.x0 == r.x1 && r.y0 == r.y1 && r.x0 != FZ_MAX_INF_RECT))
  {
    if (r.x0 == FZ_MAX_INF_RECT) return fz_make_rect(p.x, p.y, p.x, p.y);
  }
  if (p.x < r.x0) r.x0 = p.x;
  if (p.x > r.x1) r.x1 = p.x;
  if (p.y < r.y0) r.y0 = p.y;
  if (p.y > r.y1) r.y1 = p.y;
  return r;
}

fz_rect fz_rect_from_irect(fz_irect r) { return fz_make_rect(r.x0, r.y0, r.x1, r.y1); }

static int clamp_int(double v)
{
  return v < FZ_MIN_INF_RECT ? FZ_MIN_INF_RECT : v > FZ_MAX_INF_RECT ? FZ_MAX_INF_RECT : (int)v;
}

/* outward to whole pixels, with a little slack so that 2.0001 stays 2 */
fz_irect fz_round_rect(fz_rect r)
{
  fz_irect i = {clamp_int(floor(r.x0 + 0.001)), clamp_int(floor(r.y0 + 0.001)), clamp_int(ceil(r.x1 - 0.001)),
                clamp_int(ceil(r.y1 - 0.001))};
  if (i.x1 < i.x0) i.x1 = i.x0;
  if (i.y1 < i.y0) i.y1 = i.y0;
  return i;
}

fz_irect fz_irect_from_rect(fz_rect r)
{
  if (fz_is_empty_rect(r)) return fz_empty_irect;
  if (fz_is_infinite_rect(r)) return fz_infinite_irect;
  fz_irect i = {clamp_int(floor(r.x0)), clamp_int(floor(r.y0)), clamp_int(ceil(r.x1)), clamp_int(ceil(r.y1))};
  return i;
}

int fz_is_point_inside_irect(int x, int y, fz_irect r) { return x >= r.x0 && x < r.x1 && y >= r.y0 && y < r.y1; }

fz_rect fz_expand_rect(fz_rect r, float e)
{
  if (fz_is_empty_rect(r) || fz_is_infinite_rect(r)) return r;
  return fz_make_rect(r.x0 - e, r.y0 - e, r.x1 + e, r.y1 + e);
}

fz_matrix fz_concat(fz_matrix l, fz_matrix r)
{
  fz_matrix m;
  m.a = l.a * r.a + l.b * r.c;
  m.b = l.a * r.b + l.b * r.d;
  m.c = l.c * r.a + l.d * r.c;
  m.d = l.c * r.b + l.d * r.d;
  m.e = l.e * r.a + l.f * r.c + r.e;
  m.f = l.e * r.b + l.f * r.d + r.f;
  return m;
}

fz_matrix fz_scale(float sx, float sy) { return fz_make_matrix(sx, 0, 0, sy, 0, 0); }
fz_matrix fz_translate(float tx, float ty) { return fz_make_matrix(1, 0, 0, 1, tx, ty); }

fz_matrix fz_rotate(float deg)
{
  /* exact for quarter turns */
  while (deg < 0) deg += 360;
  while (deg >= 360) deg -= 360;
  float s, c;
  if (deg == 0) { s = 0; c = 1; }
  else if (deg == 90) { s = 1; c = 0; }
  else if (deg == 180) { s = 0; c = -1; }
  else if (deg == 270) { s = -1; c = 0; }
  else { s = sinf(deg * (float)M_PI / 180); c = cosf(deg * (float)M_PI / 180); }
  return fz_make_matrix(c, s, -s, c, 0, 0);
}

fz_matrix fz_pre_scale(fz_matrix m, float sx, float sy) { return fz_concat(fz_scale(sx, sy), m); }
fz_matrix fz_pre_translate(fz_matrix m, float tx, float ty) { return fz_concat(fz_translate(tx, ty), m); }
fz_matrix fz_pre_rotate(fz_matrix m, float deg) { return fz_concat(fz_rotate(deg), m); }

fz_matrix fz_invert_matrix(fz_matrix m)
{
  double det = (double)m.a * m.d - (double)m.b * m.c;
  if (det > -DBL_EPSILON && det < DBL_EPSILON) return m;
  double r = 1 / det;
  fz_matrix i;
  i.a = m.d * r;
  i.b = -m.b * r;
  i.c = -m.c * r;
  i.d = m.a * r;
  i.e = -m.e * i.a - m.f * i.c;
  i.f = -m.e * i.b - m.f * i.d;
  return i;
}

float fz_matrix_expansion(fz_matrix m) { return sqrtf(fabsf(m.a * m.d - m.b * m.c)); }

fz_point fz_transform_point(fz_point p, fz_matrix m)
{
  return fz_make_point(p.x * m.a + p.y * m.c + m.e, p.x * m.b + p.y * m.d + m.f);
}
fz_point fz_transform_point_xy(float x, float y, fz_matrix m) { return fz_transform_point(fz_make_point(x, y), m); }
fz_point fz_transform_vector(fz_point p, fz_matrix m) { return fz_make_point(p.x * m.a + p.y * m.c, p.x * m.b + p.y * m.d); }

fz_rect fz_transform_rect(fz_rect r, fz_matrix m)
{
  if (fz_is_infinite_rect(r) || fz_is_empty_rect(r)) return r;
  fz_point p[4] = {fz_transform_point_xy(r.x0, r.y0, m), fz_transform_point_xy(r.x1, r.y0, m),
                   fz_transform_point_xy(r.x0, r.y1, m), fz_transform_point_xy(r.x1, r.y1, m)};
  fz_rect o = fz_make_rect(p[0].x, p[0].y, p[0].x, p[0].y);
  for (int i = 1; i < 4; i++)
  {
    o.x0 = fminf(o.x0, p[i].x); o.x1 = fmaxf(o.x1, p[i].x);
    o.y0 = fminf(o.y0, p[i].y); o.y1 = fmaxf(o.y1, p[i].y);
  }
  return o;
}

/* ---- buffers ------------------------------------------------------------------------------------------------------ */

fz_buffer *fz_new_buffer(fz_context *ctx, size_t cap)
{
  fz_buffer *b = fz_malloc_struct(ctx, fz_buffer);
  b->refs = 1;
  b->cap = cap > 1 ? cap : 1;
  b->data = fz_malloc(ctx, b->cap);
  return b;
}

fz_buffer *fz_new_buffer_from_copied_data(fz_context *ctx, const unsigned char *data, size_t size)
{
  fz_buffer *b = fz_new_buffer(ctx, size);
  memcpy(b->data, data, size);
  b->len = size;
  return b;
}

fz_buffer *fz_keep_buffer(fz_context *ctx, fz_buffer *b) { (void)ctx; if (b) b->refs++; return b; }

void fz_drop_buffer(fz_context *ctx, fz_buffer *b)
{
  (void)ctx;
  if (!b || --b->refs > 0) return;
  if (!b->shared) free(b->data);
  free(b);
}

void fz_resize_buffer(fz_context *ctx, fz_buffer *b, size_t cap)
{
  if (cap < 1) cap = 1;
  b->data = fz_realloc(ctx, b->data, cap);
  b->cap = cap;
  if (b->len > cap) b->len = cap;
}

void fz_grow_buffer(fz_context *ctx, fz_buffer *b) { fz_resize_buffer(ctx, b, b->cap > 16 ? b->cap * 2 : 256); }
void fz_trim_buffer(fz_context *ctx, fz_buffer *b) { if (b->cap > b->len + 1) fz_resize_buffer(ctx, b, b->len + 1); }
void fz_clear_buffer(fz_context *ctx, fz_buffer *b) { (void)ctx; b->len = 0; }

static void buf_need(fz_context *ctx, fz_buffer *b, size_t extra)
{
  if (b->len + extra <= b->cap) return;
  size_t c = b->cap ? b->cap : 256;
  while (c < b->len + extra) c *= 2;
  fz_resize_buffer(ctx, b, c);
}

void fz_terminate_buffer(fz_context *ctx, fz_buffer *b)
{
  buf_need(ctx, b, 1);
  b->data[b->len] = 0;
}

size_t fz_buffer_storage(fz_context *ctx, fz_buffer *b, unsigned char **data)
{
  (void)ctx;
  if (data) *data = b ? b->data : NULL;
  return b ? b->len : 0;
}

void fz_append_data(fz_context *ctx, fz_buffer *b, const void *data, size_t len)
{
  buf_need(ctx, b, len);
  memcpy(b->data + b->len, data, len);
  b->len += len;
}

void fz_append_string(fz_context *ctx, fz_buffer *b, const char *s) { fz_append_data(ctx, b, s, strlen(s)); }
void fz_append_byte(fz_context *ctx, fz_buffer *b, int c) { unsigned char u = c; fz_append_data(ctx, b, &u, 1); }

void fz_append_vprintf(fz_context *ctx, fz_buffer *b, const char *fmt, va_list ap)
{
  va_list cp;
  va_copy(cp, ap);
  int n = vsnprintf(NULL, 0, fmt, cp);
  va_end(cp);
  if (n < 0) return;
  buf_need(ctx, b, (size_t)n + 1);
  vsnprintf((char *)b->data + b->len, (size_t)n + 1, fmt, ap);
  b->len += n;
}

void fz_append_printf(fz_context *ctx, fz_buffer *b, const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  fz_append_vprintf(ctx, b, fmt, ap);
  va_end(ap);
}

fz_buffer *fz_read_file(fz_context *ctx, const char *path)
{
  fz_stream *s = fz_open_file(ctx, path);
  fz_buffer *b = NULL;
  fz_try(ctx) b = fz_read_all(ctx, s, 0);
  fz_always(ctx) fz_drop_stream(ctx, s);
  fz_catch(ctx) fz_rethrow(ctx);
  return b;
}

/* ---- streams ------------------------------------------------------------------------------------------------------ */

struct fz_stream
{
  int refs;
  FILE *file;
  char *filename;
  const unsigned char *mem;
  size_t mem_len, mem_pos;
  fz_buffer *keep;
  fz_stream *leech_from; /* a leecher: reads from this, and copies into keep */
  int eof;
};

fz_stream *fz_open_file(fz_context *ctx, const char *path)
{
  FILE *f = fopen(path, "rb");
  if (!f) fz_throw(ctx, FZ_ERROR_SYSTEM, "cannot open %s: %s", path, strerror(errno));
  fz_stream *s = fz_malloc_struct(ctx, fz_stream);
  s->refs = 1;
  s->file = f;
  s->filename = fz_strdup(ctx, path);
  return s;
}

fz_stream *fz_open_memory(fz_context *ctx, const unsigned char *data, size_t len)
{
  fz_stream *s = fz_malloc_struct(ctx, fz_stream);
  s->refs = 1;
  s->mem = data;
  s->mem_len = len;
  return s;
}

fz_stream *fz_open_buffer(fz_context *ctx, fz_buffer *b)
{
  fz_stream *s = fz_open_memory(ctx, b->data, b->len);
  s->keep = fz_keep_buffer(ctx, b);
  return s;
}

fz_stream *fz_keep_stream(fz_context *ctx, fz_stream *s) { (void)ctx; if (s) s->refs++; return s; }

void fz_drop_stream(fz_context *ctx, fz_stream *s)
{
  if (!s || --s->refs > 0) return;
  if (s->file) fclose(s->file);
  fz_drop_stream(ctx, s->leech_from);
  free(s->filename);
  fz_drop_buffer(ctx, s->keep);
  free(s);
}

const char *fz_stream_filename(fz_stream *s) { return s ? s->filename : NULL; }

fz_stream *fz_open_leecher(fz_context *ctx, fz_stream *chain, fz_buffer *buf)
{
  fz_stream *s = fz_malloc_struct(ctx, fz_stream);
  s->refs = 1;
  s->leech_from = fz_keep_stream(ctx, chain);
  s->keep = fz_keep_buffer(ctx, buf);
  return s;
}

size_t fz_read(fz_context *ctx, fz_stream *s, unsigned char *data, size_t len)
{
  if (s->leech_from)
  {
    size_t n = fz_read(ctx, s->leech_from, data, len);
    fz_append_data(ctx, s->keep, data, n);
    return n;
  }
  if (s->file)
  {
    size_t n = fread(data, 1, len, s->file);
    if (n < len && ferror(s->file)) fz_throw(ctx, FZ_ERROR_SYSTEM, "read error");
    return n;
  }
  size_t left = s->mem_len - s->mem_pos;
  if (len > left) len = left;
  memcpy(data, s->mem + s->mem_pos, len);
  s->mem_pos += len;
  return len;
}

size_t fz_skip(fz_context *ctx, fz_stream *s, size_t len)
{
  unsigned char tmp[4096];
  size_t done = 0;
  while (done < len)
  {
    size_t k = len - done > sizeof tmp ? sizeof tmp : len - done;
    size_t n = fz_read(ctx, s, tmp, k);
    done += n;
    if (n < k) break;
  }
  return done;
}

int fz_read_byte(fz_context *ctx, fz_stream *s)
{
  unsigned char c;
  return fz_read(ctx, s, &c, 1) == 1 ? c : EOF;
}

int fz_peek_byte(fz_context *ctx, fz_stream *s)
{
  if (s->leech_from) return fz_peek_byte(ctx, s->leech_from);
  if (s->file)
  {
    int c = fgetc(s->file);
    if (c != EOF) ungetc(c, s->file);
    return c;
  }
  (void)ctx;
  return s->mem_pos < s->mem_len ? s->mem[s->mem_pos] : EOF;
}

int64_t fz_tell(fz_context *ctx, fz_stream *s)
{
  (void)ctx;
  return s->file ? (int64_t)ftello(s->file) : (int64_t)s->mem_pos;
}

void fz_seek(fz_context *ctx, fz_stream *s, int64_t off, int whence)
{
  (void)ctx;
  if (s->file) { fseeko(s->file, off, whence); return; }
  int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? (int64_t)s->mem_pos : (int64_t)s->mem_len;
  int64_t p = base + off;
  s->mem_pos = p < 0 ? 0 : p > (int64_t)s->mem_len ? s->mem_len : (size_t)p;
}

fz_buffer *fz_read_all(fz_context *ctx, fz_stream *s, size_t initial)
{
  fz_buffer *b = fz_new_buffer(ctx, initial > 1024 ? initial : 1024);
  fz_try(ctx)
  {
    for (;;)
    {
      if (b->len == b->cap) fz_grow_buffer(ctx, b);
      size_t n = fz_read(ctx, s, b->data + b->len, b->cap - b->len);
      if (n == 0) break;
      b->len += n;
    }
  }
  fz_catch(ctx)
  {
    fz_drop_buffer(ctx, b);
    fz_rethrow(ctx);
  }
  return b;
}

fz_buffer *fz_read_best(fz_context *ctx, fz_stream *s, size_t initial, int *truncated, size_t worst_case)
{
  (void)worst_case;
  if (truncated) *truncated = 0;
  return fz_read_all(ctx, s, initial);
}

/* ---- colour ------------------------------------------------------------------------------------------------------- */

static fz_colorspace cs_gray = {-1, 1, "DeviceGray"}, cs_rgb = {-1, 3, "DeviceRGB"}, cs_cmyk = {-1, 4, "DeviceCMYK"};
const fz_color_params fz_default_color_params = {1, 1, 0, 0};

fz_colorspace *fz_device_gray(fz_context *ctx) { (void)ctx; return &cs_gray; }
fz_colorspace *fz_device_rgb(fz_context *ctx) { (void)ctx; return &cs_rgb; }
fz_colorspace *fz_device_cmyk(fz_context *ctx) { (void)ctx; return &cs_cmyk; }
fz_colorspace *fz_keep_colorspace(fz_context *ctx, fz_colorspace *cs) { (void)ctx; return cs; }
void fz_drop_colorspace(fz_context *ctx, fz_colorspace *cs) { (void)ctx; (void)cs; }
int fz_colorspace_n(fz_context *ctx, fz_colorspace *cs) { (void)ctx; return cs ? cs->n : 0; }
const char *fz_colorspace_name(fz_context *ctx, fz_colorspace *cs) { (void)ctx; return cs ? cs->name : "None"; }

void rt_cmyk_to_rgb(const float cmyk[4], float rgb[3]); /* color.c */

void fz_convert_color(fz_context *ctx, fz_colorspace *src, const float *sv, fz_colorspace *dst, float *dv,
                      fz_colorspace *prf, fz_color_params params)
{
  (void)ctx; (void)prf; (void)params;
  float rgb[3];
  int sn = src ? src->n : 3;
  if (sn == 1) rgb[0] = rgb[1] = rgb[2] = sv[0];
  else if (sn == 4) rt_cmyk_to_rgb(sv, rgb);
  else memcpy(rgb, sv, sizeof rgb);
  int dn = dst ? dst->n : 3;
  if (dn == 3) memcpy(dv, rgb, sizeof rgb);
  else if (dn == 1) dv[0] = 0.3f * rgb[0] + 0.59f * rgb[1] + 0.11f * rgb[2];
  else
  {
    /* RGB → CMYK, naively (nothing asks for it today) */
    float k = 1 - fmaxf(rgb[0], fmaxf(rgb[1], rgb[2]));
    float d = k < 1 ? 1 - k : 1;
    dv[0] = (1 - rgb[0] - k) / d; dv[1] = (1 - rgb[1] - k) / d; dv[2] = (1 - rgb[2] - k) / d; dv[3] = k;
  }
}

/* ---- paths -------------------------------------------------------------------------------------------------------- */

struct fz_path
{
  int refs;
  int ncmd, capcmd, ncoord, capcoord;
  unsigned char *cmd;
  float *coord;
  float cx, cy, sx, sy; /* current point, subpath start */
};

fz_path *fz_new_path(fz_context *ctx)
{
  fz_path *p = fz_malloc_struct(ctx, fz_path);
  p->refs = 1;
  return p;
}

fz_path *fz_keep_path(fz_context *ctx, const fz_path *p)
{
  (void)ctx;
  if (p) ((fz_path *)p)->refs++;
  return (fz_path *)p;
}

void fz_drop_path(fz_context *ctx, const fz_path *cp)
{
  (void)ctx;
  fz_path *p = (fz_path *)cp;
  if (!p || --p->refs > 0) return;
  free(p->cmd);
  free(p->coord);
  free(p);
}

fz_path *fz_clone_path(fz_context *ctx, const fz_path *p)
{
  fz_path *c = fz_new_path(ctx);
  c->ncmd = c->capcmd = p->ncmd;
  c->ncoord = c->capcoord = p->ncoord;
  c->cmd = fz_malloc(ctx, p->ncmd ? p->ncmd : 1);
  c->coord = fz_malloc(ctx, sizeof(float) * (p->ncoord ? p->ncoord : 1));
  memcpy(c->cmd, p->cmd, p->ncmd);
  memcpy(c->coord, p->coord, sizeof(float) * p->ncoord);
  c->cx = p->cx; c->cy = p->cy; c->sx = p->sx; c->sy = p->sy;
  return c;
}

static void path_put(fz_context *ctx, fz_path *p, char c, int n, const float *v)
{
  if (p->ncmd == p->capcmd)
  {
    p->capcmd = p->capcmd ? p->capcmd * 2 : 16;
    p->cmd = fz_realloc(ctx, p->cmd, p->capcmd);
  }
  if (p->ncoord + n > p->capcoord)
  {
    while (p->ncoord + n > p->capcoord) p->capcoord = p->capcoord ? p->capcoord * 2 : 32;
    p->coord = fz_realloc(ctx, p->coord, sizeof(float) * p->capcoord);
  }
  p->cmd[p->ncmd++] = c;
  memcpy(p->coord + p->ncoord, v, sizeof(float) * n);
  p->ncoord += n;
  if (n >= 2) { p->cx = v[n - 2]; p->cy = v[n - 1]; }
}

void fz_moveto(fz_context *ctx, fz_path *p, float x, float y)
{
  /* a moveto right after another replaces it */
  if (p->ncmd > 0 && p->cmd[p->ncmd - 1] == 'M')
  {
    p->coord[p->ncoord - 2] = x;
    p->coord[p->ncoord - 1] = y;
    p->cx = p->sx = x;
    p->cy = p->sy = y;
    return;
  }
  float v[2] = {x, y};
  path_put(ctx, p, 'M', 2, v);
  p->sx = x;
  p->sy = y;
}

static void ensure_start(fz_context *ctx, fz_path *p)
{
  if (p->ncmd == 0) fz_moveto(ctx, p, 0, 0);
  else if (p->cmd[p->ncmd - 1] == 'Z') fz_moveto(ctx, p, p->sx, p->sy);
}

void fz_lineto(fz_context *ctx, fz_path *p, float x, float y)
{
  ensure_start(ctx, p);
  float v[2] = {x, y};
  path_put(ctx, p, 'L', 2, v);
}

void fz_curveto(fz_context *ctx, fz_path *p, float x1, float y1, float x2, float y2, float x3, float y3)
{
  ensure_start(ctx, p);
  float v[6] = {x1, y1, x2, y2, x3, y3};
  path_put(ctx, p, 'C', 6, v);
}

void fz_curvetov(fz_context *ctx, fz_path *p, float x2, float y2, float x3, float y3)
{
  ensure_start(ctx, p);
  fz_curveto(ctx, p, p->cx, p->cy, x2, y2, x3, y3);
}

void fz_curvetoy(fz_context *ctx, fz_path *p, float x1, float y1, float x3, float y3)
{
  fz_curveto(ctx, p, x1, y1, x3, y3, x3, y3);
}

void fz_quadto(fz_context *ctx, fz_path *p, float x1, float y1, float x2, float y2)
{
  ensure_start(ctx, p);
  float v[4] = {x1, y1, x2, y2};
  path_put(ctx, p, 'Q', 4, v);
}

void fz_closepath(fz_context *ctx, fz_path *p)
{
  if (p->ncmd == 0 || p->cmd[p->ncmd - 1] == 'Z') return;
  path_put(ctx, p, 'Z', 0, NULL);
  p->cx = p->sx;
  p->cy = p->sy;
}

void fz_rectto(fz_context *ctx, fz_path *p, float x0, float y0, float x1, float y1)
{
  fz_moveto(ctx, p, x0, y0);
  fz_lineto(ctx, p, x1, y0);
  fz_lineto(ctx, p, x1, y1);
  fz_lineto(ctx, p, x0, y1);
  fz_closepath(ctx, p);
}

fz_point fz_currentpoint(fz_context *ctx, fz_path *p) { (void)ctx; return fz_make_point(p->cx, p->cy); }

void fz_transform_path(fz_context *ctx, fz_path *p, fz_matrix m)
{
  (void)ctx;
  for (int i = 0; i + 1 < p->ncoord; i += 2)
  {
    fz_point q = fz_transform_point_xy(p->coord[i], p->coord[i + 1], m);
    p->coord[i] = q.x;
    p->coord[i + 1] = q.y;
  }
}

void fz_walk_path(fz_context *ctx, const fz_path *p, const fz_path_walker *w, void *arg)
{
  const float *v = p->coord;
  for (int i = 0; i < p->ncmd; i++)
  {
    switch (p->cmd[i])
    {
      case 'M': w->moveto(ctx, arg, v[0], v[1]); v += 2; break;
      case 'L': w->lineto(ctx, arg, v[0], v[1]); v += 2; break;
      case 'C': w->curveto(ctx, arg, v[0], v[1], v[2], v[3], v[4], v[5]); v += 6; break;
      case 'Q':
        if (w->quadto) w->quadto(ctx, arg, v[0], v[1], v[2], v[3]);
        else
        {
          /* as a cubic: needs the current point, which only the walker knows; quads come only from fonts here */
          w->lineto(ctx, arg, v[2], v[3]);
        }
        v += 4;
        break;
      case 'Z': w->closepath(ctx, arg); break;
    }
  }
}

/* Raw access for the TDL writer and the hash (rt-internal). */
int rt_path_data(const fz_path *p, const unsigned char **cmd, const float **coord, int *ncoord)
{
  *cmd = p->cmd;
  *coord = p->coord;
  *ncoord = p->ncoord;
  return p->ncmd;
}

fz_rect fz_bound_path(fz_context *ctx, const fz_path *p, const fz_stroke_state *s, fz_matrix m)
{
  (void)ctx;
  if (p->ncoord < 2) return fz_empty_rect;
  fz_point q = fz_transform_point_xy(p->coord[0], p->coord[1], m);
  fz_rect r = fz_make_rect(q.x, q.y, q.x, q.y);
  for (int i = 2; i + 1 < p->ncoord; i += 2)
  {
    q = fz_transform_point_xy(p->coord[i], p->coord[i + 1], m);
    if (q.x < r.x0) r.x0 = q.x;
    if (q.x > r.x1) r.x1 = q.x;
    if (q.y < r.y0) r.y0 = q.y;
    if (q.y > r.y1) r.y1 = q.y;
  }
  if (s)
  {
    float e = s->linewidth * 0.5f;
    if (e <= 0) e = 0.5f / fmaxf(fz_matrix_expansion(m), 1e-6f); /* hairlines: one device pixel */
    if (s->linejoin == FZ_LINEJOIN_MITER || s->linejoin == FZ_LINEJOIN_MITER_XPS)
      e *= fmaxf(1, s->miterlimit);
    if (s->start_cap == FZ_LINECAP_SQUARE || s->end_cap == FZ_LINECAP_SQUARE) e *= 1.4143f;
    /* the larger axis scale of m */
    float sx = sqrtf(m.a * m.a + m.b * m.b), sy = sqrtf(m.c * m.c + m.d * m.d);
    r = fz_expand_rect(r, e * fmaxf(sx, sy));
  }
  return r;
}

/* ---- stroke states ------------------------------------------------------------------------------------------------ */

const fz_stroke_state fz_default_stroke_state = {-2, 0, 0, 0, 0, 1, 10, 0, 0};

fz_stroke_state *fz_new_stroke_state_with_dash_len(fz_context *ctx, int len)
{
  if (len < 0) len = 0;
  fz_stroke_state *s = fz_calloc(ctx, 1, sizeof(fz_stroke_state) + sizeof(float) * len);
  s->refs = 1;
  s->linewidth = 1;
  s->miterlimit = 10;
  return s;
}

fz_stroke_state *fz_new_stroke_state(fz_context *ctx) { return fz_new_stroke_state_with_dash_len(ctx, 0); }

fz_stroke_state *fz_keep_stroke_state(fz_context *ctx, const fz_stroke_state *s)
{
  (void)ctx;
  if (s && s->refs > 0) ((fz_stroke_state *)s)->refs++;
  return (fz_stroke_state *)s;
}

void fz_drop_stroke_state(fz_context *ctx, const fz_stroke_state *s)
{
  (void)ctx;
  if (!s || s->refs < 0) return;
  if (--((fz_stroke_state *)s)->refs == 0) free((void *)s);
}

fz_stroke_state *fz_clone_stroke_state(fz_context *ctx, const fz_stroke_state *s)
{
  int n = s->dash_len > 0 ? s->dash_len : 0;
  fz_stroke_state *c = fz_new_stroke_state_with_dash_len(ctx, n);
  memcpy(c, s, sizeof(fz_stroke_state) + sizeof(float) * n);
  c->refs = 1;
  return c;
}

/* ---- text --------------------------------------------------------------------------------------------------------- */

fz_text *fz_new_text(fz_context *ctx)
{
  fz_text *t = fz_malloc_struct(ctx, fz_text);
  t->refs = 1;
  return t;
}

fz_text *fz_keep_text(fz_context *ctx, const fz_text *t)
{
  (void)ctx;
  if (t) ((fz_text *)t)->refs++;
  return (fz_text *)t;
}

void fz_drop_text(fz_context *ctx, const fz_text *ct)
{
  fz_text *t = (fz_text *)ct;
  if (!t || --t->refs > 0) return;
  for (fz_text_span *s = t->head, *n; s; s = n)
  {
    n = s->next;
    fz_drop_font(ctx, s->font);
    free(s->items);
    free(s);
  }
  free(t);
}

void fz_show_glyph(fz_context *ctx, fz_text *text, fz_font *font, fz_matrix trm, int gid, int ucs, int wmode,
                   int bidi_level, fz_bidi_direction markup_dir, fz_text_language language)
{
  (void)bidi_level; (void)markup_dir; (void)language;
  fz_text_span *s = text->tail;
  if (!s || s->font != font || s->wmode != wmode || s->trm.a != trm.a || s->trm.b != trm.b || s->trm.c != trm.c ||
      s->trm.d != trm.d)
  {
    s = fz_malloc_struct(ctx, fz_text_span);
    s->font = fz_keep_font(ctx, font);
    s->trm = fz_make_matrix(trm.a, trm.b, trm.c, trm.d, 0, 0);
    s->wmode = wmode;
    if (text->tail) text->tail->next = s;
    else text->head = s;
    text->tail = s;
  }
  if (s->len == s->cap)
  {
    s->cap = s->cap ? s->cap * 2 : 16;
    s->items = fz_realloc(ctx, s->items, sizeof(fz_text_item) * s->cap);
  }
  fz_text_item *it = &s->items[s->len++];
  it->x = trm.e;
  it->y = trm.f;
  it->gid = gid;
  it->ucs = ucs;
}

fz_rect fz_bound_text(fz_context *ctx, const fz_text *text, const fz_stroke_state *stroke, fz_matrix ctm)
{
  fz_rect r = fz_empty_rect;
  for (fz_text_span *s = text->head; s; s = s->next)
  {
    float asc = fz_font_ascender(ctx, s->font), desc = fz_font_descender(ctx, s->font);
    for (int i = 0; i < s->len; i++)
    {
      fz_text_item *it = &s->items[i];
      if (it->gid < 0) continue;
      fz_matrix m = s->trm;
      m.e = it->x;
      m.f = it->y;
      float adv = fz_advance_glyph(ctx, s->font, it->gid, s->wmode);
      fz_rect g = fz_make_rect(0, desc, adv > 0 ? adv : 0.5f, asc);
      r = fz_union_rect(r, fz_transform_rect(g, fz_concat(m, ctm)));
    }
  }
  if (stroke && !fz_is_empty_rect(r)) r = fz_expand_rect(r, stroke->linewidth * fz_matrix_expansion(ctm));
  return r;
}

/* ---- shades ------------------------------------------------------------------------------------------------------- */

fz_shade *fz_keep_shade(fz_context *ctx, fz_shade *s) { (void)ctx; if (s) s->refs++; return s; }

void fz_drop_shade(fz_context *ctx, fz_shade *s)
{
  (void)ctx;
  if (!s) return;
  if (--s->refs > 0) return;
  free(s->function);
  free(s);
}

fz_rect fz_bound_shade(fz_context *ctx, fz_shade *s, fz_matrix ctm)
{
  (void)ctx;
  if (fz_is_infinite_rect(s->bbox)) return fz_infinite_rect;
  return fz_transform_rect(s->bbox, fz_concat(s->matrix, ctm));
}

/* ---- devices ------------------------------------------------------------------------------------------------------ */

fz_device *fz_new_device_of_size(fz_context *ctx, int size)
{
  fz_device *d = fz_calloc(ctx, 1, size);
  d->refs = 1;
  return d;
}

fz_device *fz_keep_device(fz_context *ctx, fz_device *d) { (void)ctx; if (d) d->refs++; return d; }

void fz_close_device(fz_context *ctx, fz_device *d)
{
  if (d && d->close_device) d->close_device(ctx, d);
  if (d) d->close_device = NULL;
}

void fz_drop_device(fz_context *ctx, fz_device *d)
{
  if (!d || --d->refs > 0) return;
  if (d->drop_device) d->drop_device(ctx, d);
  free(d);
}

#define CALL(fn, ...) do { if (dev && dev->fn) dev->fn(ctx, dev, __VA_ARGS__); } while (0)

void fz_fill_path(fz_context *ctx, fz_device *dev, const fz_path *path, int eo, fz_matrix ctm, fz_colorspace *cs,
                  const float *color, float alpha, fz_color_params cp)
{ CALL(fill_path, path, eo, ctm, cs, color, alpha, cp); }
void fz_stroke_path(fz_context *ctx, fz_device *dev, const fz_path *path, const fz_stroke_state *s, fz_matrix ctm,
                    fz_colorspace *cs, const float *color, float alpha, fz_color_params cp)
{ CALL(stroke_path, path, s, ctm, cs, color, alpha, cp); }
void fz_clip_path(fz_context *ctx, fz_device *dev, const fz_path *path, int eo, fz_matrix ctm, fz_rect sc)
{ CALL(clip_path, path, eo, ctm, sc); }
void fz_clip_stroke_path(fz_context *ctx, fz_device *dev, const fz_path *path, const fz_stroke_state *s,
                         fz_matrix ctm, fz_rect sc)
{ CALL(clip_stroke_path, path, s, ctm, sc); }
void fz_fill_text(fz_context *ctx, fz_device *dev, const fz_text *t, fz_matrix ctm, fz_colorspace *cs,
                  const float *color, float alpha, fz_color_params cp)
{ CALL(fill_text, t, ctm, cs, color, alpha, cp); }
void fz_stroke_text(fz_context *ctx, fz_device *dev, const fz_text *t, const fz_stroke_state *s, fz_matrix ctm,
                    fz_colorspace *cs, const float *color, float alpha, fz_color_params cp)
{ CALL(stroke_text, t, s, ctm, cs, color, alpha, cp); }
void fz_clip_text(fz_context *ctx, fz_device *dev, const fz_text *t, fz_matrix ctm, fz_rect sc)
{ CALL(clip_text, t, ctm, sc); }
void fz_clip_stroke_text(fz_context *ctx, fz_device *dev, const fz_text *t, const fz_stroke_state *s, fz_matrix ctm,
                         fz_rect sc)
{ CALL(clip_stroke_text, t, s, ctm, sc); }
void fz_ignore_text(fz_context *ctx, fz_device *dev, const fz_text *t, fz_matrix ctm) { CALL(ignore_text, t, ctm); }
void fz_fill_shade(fz_context *ctx, fz_device *dev, fz_shade *sh, fz_matrix ctm, float alpha, fz_color_params cp)
{ CALL(fill_shade, sh, ctm, alpha, cp); }
void fz_fill_image(fz_context *ctx, fz_device *dev, fz_image *img, fz_matrix ctm, float alpha, fz_color_params cp)
{ CALL(fill_image, img, ctm, alpha, cp); }
void fz_fill_image_mask(fz_context *ctx, fz_device *dev, fz_image *img, fz_matrix ctm, fz_colorspace *cs,
                        const float *color, float alpha, fz_color_params cp)
{ CALL(fill_image_mask, img, ctm, cs, color, alpha, cp); }
void fz_clip_image_mask(fz_context *ctx, fz_device *dev, fz_image *img, fz_matrix ctm, fz_rect sc)
{ CALL(clip_image_mask, img, ctm, sc); }
void fz_pop_clip(fz_context *ctx, fz_device *dev) { if (dev && dev->pop_clip) dev->pop_clip(ctx, dev); }
void fz_begin_mask(fz_context *ctx, fz_device *dev, fz_rect area, int lum, fz_colorspace *cs, const float *bc,
                   fz_color_params cp)
{ CALL(begin_mask, area, lum, cs, bc, cp); }
void fz_end_mask(fz_context *ctx, fz_device *dev) { if (dev && dev->end_mask) dev->end_mask(ctx, dev, NULL); }
void fz_begin_group(fz_context *ctx, fz_device *dev, fz_rect area, fz_colorspace *cs, int iso, int ko, int blend,
                    float alpha)
{ CALL(begin_group, area, cs, iso, ko, blend, alpha); }
void fz_end_group(fz_context *ctx, fz_device *dev) { if (dev && dev->end_group) dev->end_group(ctx, dev); }
int fz_begin_tile_id(fz_context *ctx, fz_device *dev, fz_rect area, fz_rect view, float xs, float ys, fz_matrix ctm,
                     int id)
{
  if (dev && dev->begin_tile) return dev->begin_tile(ctx, dev, area, view, xs, ys, ctm, id, 0);
  return 0;
}
void fz_begin_tile(fz_context *ctx, fz_device *dev, fz_rect area, fz_rect view, float xs, float ys, fz_matrix ctm)
{ (void)fz_begin_tile_id(ctx, dev, area, view, xs, ys, ctm, 0); }
void fz_end_tile(fz_context *ctx, fz_device *dev) { if (dev && dev->end_tile) dev->end_tile(ctx, dev); }
void fz_fill_figure(fz_context *ctx, fz_device *dev, fz_figure *fig, fz_matrix ctm) { CALL(fill_figure, fig, ctm); }

/* ---- display lists ------------------------------------------------------------------------------------------------ */

typedef enum
{
  N_FILL_PATH, N_STROKE_PATH, N_CLIP_PATH, N_CLIP_STROKE_PATH, N_FILL_TEXT, N_STROKE_TEXT, N_CLIP_TEXT,
  N_CLIP_STROKE_TEXT, N_IGNORE_TEXT, N_FILL_SHADE, N_FILL_IMAGE, N_FILL_IMAGE_MASK, N_CLIP_IMAGE_MASK, N_POP_CLIP,
  N_BEGIN_MASK, N_END_MASK, N_BEGIN_GROUP, N_END_GROUP, N_BEGIN_TILE, N_END_TILE, N_FILL_FIGURE
} node_kind;

typedef struct
{
  node_kind kind;
  fz_matrix ctm;
  fz_rect area, view;
  fz_path *path;
  fz_stroke_state *stroke;
  fz_text *text;
  fz_image *image;
  fz_shade *shade;
  fz_figure *figure;
  fz_colorspace *cs;
  float color[4];
  float alpha;
  float xstep, ystep;
  int i0, i1, i2; /* even_odd / luminosity / isolated, knockout, blend / tile id */
} dl_node;

struct fz_display_list
{
  int refs;
  fz_rect mediabox;
  dl_node *nodes;
  int len, cap;
};

fz_display_list *fz_new_display_list(fz_context *ctx, fz_rect mediabox)
{
  fz_display_list *l = fz_malloc_struct(ctx, fz_display_list);
  l->refs = 1;
  l->mediabox = mediabox;
  return l;
}

fz_display_list *fz_keep_display_list(fz_context *ctx, fz_display_list *l) { (void)ctx; if (l) l->refs++; return l; }

void fz_drop_display_list(fz_context *ctx, fz_display_list *l)
{
  if (!l || --l->refs > 0) return;
  for (int i = 0; i < l->len; i++)
  {
    dl_node *n = &l->nodes[i];
    fz_drop_path(ctx, n->path);
    fz_drop_stroke_state(ctx, n->stroke);
    fz_drop_text(ctx, n->text);
    fz_drop_image(ctx, n->image);
    if (n->shade) fz_drop_shade(ctx, n->shade);
    fz_drop_figure(ctx, n->figure);
  }
  free(l->nodes);
  free(l);
}

fz_rect fz_bound_display_list(fz_context *ctx, fz_display_list *l) { (void)ctx; return l->mediabox; }

typedef struct
{
  fz_device super;
  fz_display_list *list;
} list_device;

static dl_node *push(fz_context *ctx, fz_device *dev, node_kind kind, fz_matrix ctm)
{
  fz_display_list *l = ((list_device *)dev)->list;
  if (l->len == l->cap)
  {
    l->cap = l->cap ? l->cap * 2 : 64;
    l->nodes = fz_realloc(ctx, l->nodes, sizeof(dl_node) * l->cap);
  }
  dl_node *n = &l->nodes[l->len++];
  memset(n, 0, sizeof *n);
  n->kind = kind;
  n->ctm = ctm;
  n->alpha = 1;
  return n;
}

static void set_color(fz_context *ctx, dl_node *n, fz_colorspace *cs, const float *color)
{
  n->cs = cs;
  int k = cs ? fz_colorspace_n(ctx, cs) : 0;
  if (k > 4) k = 4;
  if (color) memcpy(n->color, color, sizeof(float) * k);
}

/* paths and stroke states are copied: the interpreter may keep building a path it has drawn */
static void ld_fill_path(fz_context *ctx, fz_device *dev, const fz_path *p, int eo, fz_matrix m, fz_colorspace *cs,
                         const float *color, float alpha, fz_color_params cp)
{
  (void)cp;
  dl_node *n = push(ctx, dev, N_FILL_PATH, m);
  n->path = fz_clone_path(ctx, p);
  n->i0 = eo;
  set_color(ctx, n, cs, color);
  n->alpha = alpha;
}

static void ld_stroke_path(fz_context *ctx, fz_device *dev, const fz_path *p, const fz_stroke_state *s, fz_matrix m,
                           fz_colorspace *cs, const float *color, float alpha, fz_color_params cp)
{
  (void)cp;
  dl_node *n = push(ctx, dev, N_STROKE_PATH, m);
  n->path = fz_clone_path(ctx, p);
  n->stroke = fz_clone_stroke_state(ctx, s);
  set_color(ctx, n, cs, color);
  n->alpha = alpha;
}

static void ld_clip_path(fz_context *ctx, fz_device *dev, const fz_path *p, int eo, fz_matrix m, fz_rect sc)
{
  (void)sc;
  dl_node *n = push(ctx, dev, N_CLIP_PATH, m);
  n->path = fz_clone_path(ctx, p);
  n->i0 = eo;
}

static void ld_clip_stroke_path(fz_context *ctx, fz_device *dev, const fz_path *p, const fz_stroke_state *s,
                                fz_matrix m, fz_rect sc)
{
  (void)sc;
  dl_node *n = push(ctx, dev, N_CLIP_STROKE_PATH, m);
  n->path = fz_clone_path(ctx, p);
  n->stroke = fz_clone_stroke_state(ctx, s);
}

static void ld_fill_text(fz_context *ctx, fz_device *dev, const fz_text *t, fz_matrix m, fz_colorspace *cs,
                         const float *color, float alpha, fz_color_params cp)
{
  (void)cp;
  dl_node *n = push(ctx, dev, N_FILL_TEXT, m);
  n->text = fz_keep_text(ctx, t);
  set_color(ctx, n, cs, color);
  n->alpha = alpha;
}

static void ld_stroke_text(fz_context *ctx, fz_device *dev, const fz_text *t, const fz_stroke_state *s, fz_matrix m,
                           fz_colorspace *cs, const float *color, float alpha, fz_color_params cp)
{
  (void)cp;
  dl_node *n = push(ctx, dev, N_STROKE_TEXT, m);
  n->text = fz_keep_text(ctx, t);
  n->stroke = fz_clone_stroke_state(ctx, s);
  set_color(ctx, n, cs, color);
  n->alpha = alpha;
}

static void ld_clip_text(fz_context *ctx, fz_device *dev, const fz_text *t, fz_matrix m, fz_rect sc)
{
  (void)sc;
  push(ctx, dev, N_CLIP_TEXT, m)->text = fz_keep_text(ctx, t);
}

static void ld_clip_stroke_text(fz_context *ctx, fz_device *dev, const fz_text *t, const fz_stroke_state *s,
                                fz_matrix m, fz_rect sc)
{
  (void)sc;
  dl_node *n = push(ctx, dev, N_CLIP_STROKE_TEXT, m);
  n->text = fz_keep_text(ctx, t);
  n->stroke = fz_clone_stroke_state(ctx, s);
}

static void ld_ignore_text(fz_context *ctx, fz_device *dev, const fz_text *t, fz_matrix m)
{
  push(ctx, dev, N_IGNORE_TEXT, m)->text = fz_keep_text(ctx, t);
}

static void ld_fill_shade(fz_context *ctx, fz_device *dev, fz_shade *sh, fz_matrix m, float alpha, fz_color_params cp)
{
  (void)cp;
  dl_node *n = push(ctx, dev, N_FILL_SHADE, m);
  n->shade = fz_keep_shade(ctx, sh);
  n->alpha = alpha;
}

static void ld_fill_image(fz_context *ctx, fz_device *dev, fz_image *img, fz_matrix m, float alpha, fz_color_params cp)
{
  (void)cp;
  dl_node *n = push(ctx, dev, N_FILL_IMAGE, m);
  n->image = fz_keep_image(ctx, img);
  n->alpha = alpha;
}

static void ld_fill_image_mask(fz_context *ctx, fz_device *dev, fz_image *img, fz_matrix m, fz_colorspace *cs,
                               const float *color, float alpha, fz_color_params cp)
{
  (void)cp;
  dl_node *n = push(ctx, dev, N_FILL_IMAGE_MASK, m);
  n->image = fz_keep_image(ctx, img);
  set_color(ctx, n, cs, color);
  n->alpha = alpha;
}

static void ld_clip_image_mask(fz_context *ctx, fz_device *dev, fz_image *img, fz_matrix m, fz_rect sc)
{
  (void)sc;
  push(ctx, dev, N_CLIP_IMAGE_MASK, m)->image = fz_keep_image(ctx, img);
}

static void ld_pop_clip(fz_context *ctx, fz_device *dev) { push(ctx, dev, N_POP_CLIP, fz_identity); }

static void ld_begin_mask(fz_context *ctx, fz_device *dev, fz_rect area, int lum, fz_colorspace *cs, const float *bc,
                          fz_color_params cp)
{
  (void)cp;
  dl_node *n = push(ctx, dev, N_BEGIN_MASK, fz_identity);
  n->area = area;
  n->i0 = lum;
  set_color(ctx, n, cs, bc);
}

static void ld_end_mask(fz_context *ctx, fz_device *dev, fz_function *fn)
{
  (void)fn;
  push(ctx, dev, N_END_MASK, fz_identity);
}

static void ld_begin_group(fz_context *ctx, fz_device *dev, fz_rect area, fz_colorspace *cs, int iso, int ko,
                           int blend, float alpha)
{
  dl_node *n = push(ctx, dev, N_BEGIN_GROUP, fz_identity);
  n->area = area;
  n->cs = cs;
  n->i0 = iso;
  n->i1 = ko;
  n->i2 = blend;
  n->alpha = alpha;
}

static void ld_end_group(fz_context *ctx, fz_device *dev) { push(ctx, dev, N_END_GROUP, fz_identity); }

static int ld_begin_tile(fz_context *ctx, fz_device *dev, fz_rect area, fz_rect view, float xs, float ys, fz_matrix m,
                         int id, int doc_id)
{
  (void)doc_id;
  dl_node *n = push(ctx, dev, N_BEGIN_TILE, m);
  n->area = area;
  n->view = view;
  n->xstep = xs;
  n->ystep = ys;
  n->i0 = id;
  return 0;
}

static void ld_end_tile(fz_context *ctx, fz_device *dev) { push(ctx, dev, N_END_TILE, fz_identity); }

static void ld_fill_figure(fz_context *ctx, fz_device *dev, fz_figure *fig, fz_matrix m)
{
  push(ctx, dev, N_FILL_FIGURE, m)->figure = fz_keep_figure(ctx, fig);
}

static void ld_drop(fz_context *ctx, fz_device *dev) { fz_drop_display_list(ctx, ((list_device *)dev)->list); }

fz_device *fz_new_list_device(fz_context *ctx, fz_display_list *list)
{
  list_device *d = fz_new_derived_device(ctx, list_device);
  d->list = fz_keep_display_list(ctx, list);
  d->super.drop_device = ld_drop;
  d->super.fill_path = ld_fill_path;
  d->super.stroke_path = ld_stroke_path;
  d->super.clip_path = ld_clip_path;
  d->super.clip_stroke_path = ld_clip_stroke_path;
  d->super.fill_text = ld_fill_text;
  d->super.stroke_text = ld_stroke_text;
  d->super.clip_text = ld_clip_text;
  d->super.clip_stroke_text = ld_clip_stroke_text;
  d->super.ignore_text = ld_ignore_text;
  d->super.fill_shade = ld_fill_shade;
  d->super.fill_image = ld_fill_image;
  d->super.fill_image_mask = ld_fill_image_mask;
  d->super.clip_image_mask = ld_clip_image_mask;
  d->super.pop_clip = ld_pop_clip;
  d->super.begin_mask = ld_begin_mask;
  d->super.end_mask = ld_end_mask;
  d->super.begin_group = ld_begin_group;
  d->super.end_group = ld_end_group;
  d->super.begin_tile = ld_begin_tile;
  d->super.end_tile = ld_end_tile;
  d->super.fill_figure = ld_fill_figure;
  return &d->super;
}

void fz_run_display_list(fz_context *ctx, fz_display_list *l, fz_device *dev, fz_matrix ctm, fz_rect scissor,
                         fz_cookie *cookie)
{
  (void)scissor; (void)cookie;
  const fz_rect inf = fz_infinite_rect;
  int skip_tile = 0; /* depth inside a tile whose device said it was cached */
  for (int i = 0; i < l->len; i++)
  {
    dl_node *n = &l->nodes[i];
    fz_matrix m = fz_concat(n->ctm, ctm);
    if (skip_tile)
    {
      if (n->kind == N_BEGIN_TILE) skip_tile++;
      else if (n->kind == N_END_TILE) skip_tile--;
      if (skip_tile) continue;
      fz_end_tile(ctx, dev);
      continue;
    }
    switch (n->kind)
    {
      case N_FILL_PATH: fz_fill_path(ctx, dev, n->path, n->i0, m, n->cs, n->color, n->alpha, fz_default_color_params); break;
      case N_STROKE_PATH: fz_stroke_path(ctx, dev, n->path, n->stroke, m, n->cs, n->color, n->alpha, fz_default_color_params); break;
      case N_CLIP_PATH: fz_clip_path(ctx, dev, n->path, n->i0, m, inf); break;
      case N_CLIP_STROKE_PATH: fz_clip_stroke_path(ctx, dev, n->path, n->stroke, m, inf); break;
      case N_FILL_TEXT: fz_fill_text(ctx, dev, n->text, m, n->cs, n->color, n->alpha, fz_default_color_params); break;
      case N_STROKE_TEXT: fz_stroke_text(ctx, dev, n->text, n->stroke, m, n->cs, n->color, n->alpha, fz_default_color_params); break;
      case N_CLIP_TEXT: fz_clip_text(ctx, dev, n->text, m, inf); break;
      case N_CLIP_STROKE_TEXT: fz_clip_stroke_text(ctx, dev, n->text, n->stroke, m, inf); break;
      case N_IGNORE_TEXT: fz_ignore_text(ctx, dev, n->text, m); break;
      case N_FILL_SHADE: fz_fill_shade(ctx, dev, n->shade, m, n->alpha, fz_default_color_params); break;
      case N_FILL_IMAGE: fz_fill_image(ctx, dev, n->image, m, n->alpha, fz_default_color_params); break;
      case N_FILL_IMAGE_MASK: fz_fill_image_mask(ctx, dev, n->image, m, n->cs, n->color, n->alpha, fz_default_color_params); break;
      case N_CLIP_IMAGE_MASK: fz_clip_image_mask(ctx, dev, n->image, m, inf); break;
      case N_POP_CLIP: fz_pop_clip(ctx, dev); break;
      case N_BEGIN_MASK: fz_begin_mask(ctx, dev, fz_transform_rect(n->area, ctm), n->i0, n->cs, n->color, fz_default_color_params); break;
      case N_END_MASK: fz_end_mask(ctx, dev); break;
      case N_BEGIN_GROUP: fz_begin_group(ctx, dev, fz_transform_rect(n->area, ctm), n->cs, n->i0, n->i1, n->i2, n->alpha); break;
      case N_END_GROUP: fz_end_group(ctx, dev); break;
      case N_BEGIN_TILE:
        if (fz_begin_tile_id(ctx, dev, n->area, n->view, n->xstep, n->ystep, m, n->i0)) skip_tile = 1;
        break;
      case N_END_TILE: fz_end_tile(ctx, dev); break;
      case N_FILL_FIGURE: fz_fill_figure(ctx, dev, n->figure, m); break;
    }
  }
}

/* ---- hashing a list ----------------------------------------------------------------------------------------------- */

typedef struct { uint64_t h; } hasher;
static void hb(hasher *s, const void *p, size_t n)
{
  const unsigned char *c = p;
  for (size_t i = 0; i < n; i++) { s->h ^= c[i]; s->h *= 1099511628211ULL; }
}
static void hf(hasher *s, float f) { hb(s, &f, sizeof f); }
static void hi(hasher *s, int64_t v) { hb(s, &v, sizeof v); }
static void hm(hasher *s, fz_matrix m) { hb(s, &m, sizeof m); }

static uint64_t font_hash(fz_font *f)
{
  if (!f || !f->buffer) return 0;
  if (f->hash) return f->hash;
  hasher s = {1469598103934665603ULL};
  hb(&s, f->buffer->data, f->buffer->len);
  hi(&s, f->index);
  return f->hash = s.h;
}

uint64_t fz_hash_display_list(fz_context *ctx, fz_display_list *l)
{
  (void)ctx;
  hasher s = {1469598103934665603ULL};
  hb(&s, &l->mediabox, sizeof l->mediabox);
  /* fonts by content, once each per list */
  fz_font *seen[64];
  uint64_t seen_h[64];
  int nseen = 0;
  for (int i = 0; i < l->len; i++)
  {
    dl_node *n = &l->nodes[i];
    hi(&s, n->kind);
    hm(&s, n->ctm);
    hb(&s, &n->area, sizeof n->area);
    hb(&s, n->color, sizeof n->color);
    hf(&s, n->alpha);
    hi(&s, n->i0); hi(&s, n->i1); hi(&s, n->i2);
    hi(&s, n->cs ? n->cs->n : 0);
    if (n->path)
    {
      hb(&s, n->path->cmd, n->path->ncmd);
      hb(&s, n->path->coord, sizeof(float) * n->path->ncoord);
    }
    if (n->stroke) hb(&s, n->stroke, sizeof(fz_stroke_state) + sizeof(float) * (n->stroke->dash_len > 0 ? n->stroke->dash_len : 0) - sizeof(int));
    if (n->text)
      for (fz_text_span *sp = n->text->head; sp; sp = sp->next)
      {
        uint64_t fh = 0;
        int k = 0;
        for (; k < nseen; k++)
          if (seen[k] == sp->font) { fh = seen_h[k]; break; }
        if (k == nseen)
        {
          fh = font_hash(sp->font);
          if (nseen < 64) { seen[nseen] = sp->font; seen_h[nseen++] = fh; }
        }
        hi(&s, (int64_t)fh);
        hm(&s, sp->trm);
        hi(&s, sp->wmode);
        hb(&s, sp->items, sizeof(fz_text_item) * sp->len);
      }
    if (n->image && n->image->buffer) hb(&s, n->image->buffer->data, n->image->buffer->len);
    if (n->shade)
    {
      hi(&s, n->shade->type);
      hm(&s, n->shade->matrix);
      hb(&s, &n->shade->u, sizeof n->shade->u);
      if (n->shade->function) hb(&s, n->shade->function, sizeof(float) * 256 * n->shade->function_stride);
    }
    if (n->figure)
    {
      hb(&s, n->figure->path, strlen(n->figure->path));
      hi(&s, n->figure->page);
    }
  }
  return s.h;
}

void fz_drop_shade_imp(fz_context *ctx, void *s) { fz_drop_shade(ctx, s); }
