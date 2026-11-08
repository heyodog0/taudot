// MIT. Just enough PDF for tau-tdl's pdf mode: find objects through classic xref tables and xref streams (with
// object streams), walk the page tree, read dictionaries' entries as text, and append an incremental update.
// Written for pdfTeX's and LuaTeX's output; anything else is read best-effort.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct {
  unsigned char *b;
  size_t n;
  long *off;    // object number -> byte offset (type 1), or -1
  long *stm;    // object number -> containing object stream (type 2), or -1
  long *idx;    // index within that stream
  long nobj;
  long root, prev_xref, size;
} pdf;

static const char *skip_ws(const char *p, const char *e)
{
  for (;;) {
    while (p < e && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t' || *p == '\f' || *p == 0)) p++;
    if (p < e && *p == '%') { while (p < e && *p != '\n' && *p != '\r') p++; continue; }
    return p;
  }
}

// The value after KEY in the dictionary text [p, e): its first token or balanced << >> / [ ] group.
static int dict_get(const char *p, const char *e, const char *key, const char **vs, const char **ve)
{
  size_t kl = strlen(key);
  int depth = 0;
  for (const char *q = p; q < e; q++) {
    if (q + 1 < e && q[0] == '<' && q[1] == '<') { depth++; q++; continue; }
    if (q + 1 < e && q[0] == '>' && q[1] == '>') { depth--; q++; continue; }
    if (*q == '(') { int d = 1; for (q++; q < e && d; q++) { if (*q == '\\') q++; else if (*q == '(') d++; else if (*q == ')') d--; } q--; continue; }
    if (depth == 1 && *q == '/' && (size_t)(e - q) > kl && !memcmp(q + 1, key, kl) &&
        strchr(" \t\r\n/<[(", q[1 + kl])) {
      const char *v = skip_ws(q + 1 + kl, e), *w = v;
      if (w + 1 < e && w[0] == '<' && w[1] == '<') {
        int d = 0;
        for (; w < e; w++) {
          if (w + 1 < e && w[0] == '<' && w[1] == '<') { d++; w++; }
          else if (w + 1 < e && w[0] == '>' && w[1] == '>') { d--; w++; if (!d) { w++; break; } }
        }
      } else if (*w == '[') {
        int d = 0;
        for (; w < e; w++) { if (*w == '[') d++; else if (*w == ']' && !--d) { w++; break; } }
      } else {
        // a number, a name, or "N G R"
        w++;
        while (w < e && !strchr(" \t\r\n/<>[]()", *w)) w++;
        const char *r = skip_ws(w, e);
        if (r < e && *r >= '0' && *r <= '9') {
          const char *g = r;
          while (g < e && *g >= '0' && *g <= '9') g++;
          const char *r2 = skip_ws(g, e);
          if (r2 < e && *r2 == 'R') w = r2 + 1;
        }
      }
      *vs = v, *ve = w;
      return 1;
    }
  }
  return 0;
}

static long dict_int(const char *p, const char *e, const char *key, long dflt)
{
  const char *vs, *ve;
  return dict_get(p, e, key, &vs, &ve) ? strtol(vs, NULL, 10) : dflt;
}

static unsigned char *inflate_all(const unsigned char *s, size_t n, size_t *outn)
{
  size_t cap = n * 4 + 1024;
  unsigned char *o = malloc(cap);
  z_stream z = {0};
  inflateInit(&z);
  z.next_in = (unsigned char *)s, z.avail_in = (unsigned)n;
  for (;;) {
    z.next_out = o + z.total_out, z.avail_out = (unsigned)(cap - z.total_out);
    int r = inflate(&z, Z_NO_FLUSH);
    if (r == Z_STREAM_END) break;
    if (r != Z_OK && r != Z_BUF_ERROR) break;
    if (z.avail_out == 0) { cap *= 2; o = realloc(o, cap); continue; }
    if (z.avail_in == 0) break;
  }
  *outn = z.total_out;
  inflateEnd(&z);
  return o;
}

static void grow(pdf *d, long n)
{
  if (n < d->nobj) return;
  long m = n + 1024;
  d->off = realloc(d->off, m * sizeof(long));
  d->stm = realloc(d->stm, m * sizeof(long));
  d->idx = realloc(d->idx, m * sizeof(long));
  for (long i = d->nobj; i < m; i++) d->off[i] = d->stm[i] = d->idx[i] = -2;  // -2: not yet set
  d->nobj = m;
}

static void set_entry(pdf *d, long num, long type, long f2, long f3)
{
  grow(d, num);
  if (d->off[num] != -2 || d->stm[num] != -2) return;  // newer sections come first: keep the first seen
  if (type == 1) d->off[num] = f2, d->stm[num] = -1;
  else if (type == 2) d->stm[num] = f2, d->idx[num] = f3, d->off[num] = -1;
  else d->off[num] = -1, d->stm[num] = -1;
}

// The stream data of the object whose dictionary is [ds, de) (decoded if FlateDecode).
static unsigned char *stream_data(pdf *d, const char *ds, const char *de, size_t *n)
{
  const char *p = strstr(de, "stream");
  if (!p) return NULL;
  p += 6;
  if (*p == '\r') p++;
  if (*p == '\n') p++;
  long len = dict_int(ds, de, "Length", 0);
  const char *vs, *ve;
  if (dict_get(ds, de, "Filter", &vs, &ve) && memmem(vs, ve - vs, "FlateDecode", 11))
    return inflate_all((const unsigned char *)p, len, n);
  unsigned char *o = malloc(len + 1);
  memcpy(o, p, len);
  *n = len;
  return o;
}

static int read_xref(pdf *d, long at)
{
  while (at > 0 && (size_t)at < d->n) {
    const char *p = (const char *)d->b + at, *e = (const char *)d->b + d->n;
    if (!strncmp(p, "xref", 4)) {  // a classic table
      p = skip_ws(p + 4, e);
      while (p < e && *p >= '0' && *p <= '9') {
        char *q;
        long first = strtol(p, &q, 10), cnt = strtol(q, &q, 10);
        p = skip_ws(q, e);
        for (long i = 0; i < cnt; i++, p += 20) set_entry(d, first + i, p[17] == 'n' ? 1 : 0, strtol(p, NULL, 10), 0);
        p = skip_ws(p, e);
      }
      const char *t = strstr(p, "trailer");
      if (!t) return -1;
      const char *ds = strstr(t, "<<"), *de = strstr(t, "startxref");
      if (!d->root) d->root = dict_int(ds, de, "Root", 0);
      if (!d->size) d->size = dict_int(ds, de, "Size", 0);
      at = dict_int(ds, de, "Prev", 0);
      continue;
    }
    // an xref stream: "N G obj << ... >> stream"
    const char *ds = strstr(p, "<<");
    const char *de = strstr(p, "stream");
    if (!ds || !de) return -1;
    if (!d->root) d->root = dict_int(ds, de, "Root", 0);
    if (!d->size) d->size = dict_int(ds, de, "Size", 0);
    const char *vs, *ve;
    int w[3] = {1, 2, 1};
    if (dict_get(ds, de, "W", &vs, &ve)) sscanf(vs, "[ %d %d %d", &w[0], &w[1], &w[2]);
    long index[64] = {0, dict_int(ds, de, "Size", 0)};
    int ni = 2;
    if (dict_get(ds, de, "Index", &vs, &ve)) {
      ni = 0;
      for (const char *q = vs + 1; q < ve && ni < 64;) {
        q = skip_ws(q, ve);
        if (*q == ']') break;
        char *r;
        index[ni++] = strtol(q, &r, 10);
        q = r;
      }
    }
    size_t n;
    unsigned char *data = stream_data(d, ds, de, &n);
    if (!data) return -1;
    size_t k = 0, rec = w[0] + w[1] + w[2];
    for (int s = 0; s + 1 < ni; s += 2)
      for (long i = 0; i < index[s + 1] && k + rec <= n; i++, k += rec) {
        long f[3] = {w[0] ? 0 : 1, 0, 0};
        size_t o = k;
        for (int c = 0; c < 3; c++) {
          if (!w[c]) continue;
          f[c] = 0;
          for (int b = 0; b < w[c]; b++) f[c] = f[c] << 8 | data[o++];
        }
        set_entry(d, index[s] + i, f[0], f[1], f[2]);
      }
    free(data);
    at = dict_int(ds, de, "Prev", 0);
  }
  return 0;
}

int pdf_open(pdf *d, unsigned char *b, size_t n)
{
  memset(d, 0, sizeof *d);
  d->b = b, d->n = n;
  const char *sx = NULL;
  for (size_t i = n > 1024 ? n - 1024 : 0; i + 9 < n; i++)
    if (!memcmp(b + i, "startxref", 9)) sx = (const char *)b + i;
  if (!sx) return -1;
  d->prev_xref = strtol(sx + 9, NULL, 10);
  return read_xref(d, d->prev_xref);
}

// The text of object NUM's value (dictionary, array, number...), as a malloc'd string; for a stream object, its
// dictionary. Objects inside object streams are found through their stream.
char *pdf_object(pdf *d, long num)
{
  if (num <= 0 || num >= d->nobj) return NULL;
  if (d->off[num] >= 0) {
    const char *p = (const char *)d->b + d->off[num], *e = (const char *)d->b + d->n;
    const char *o = strstr(p, "obj");
    if (!o) return NULL;
    o += 3;
    const char *end = strstr(o, "endobj"), *st = strstr(o, "stream");
    if (st && (!end || st < end)) end = st;
    if (!end) end = e;
    size_t l = end - o;
    char *r = malloc(l + 1);
    memcpy(r, o, l);
    r[l] = 0;
    return r;
  }
  if (d->stm[num] >= 0) {
    char *sd = pdf_object(d, d->stm[num]);
    if (!sd) return NULL;
    const char *p = (const char *)d->b + d->off[d->stm[num]];
    const char *ds = strstr(p, "<<"), *de = strstr(p, "stream");
    long first = dict_int(ds, de, "First", 0), cnt = dict_int(ds, de, "N", 0);
    free(sd);
    size_t n;
    unsigned char *data = stream_data(d, ds, de, &n);
    if (!data) return NULL;
    char *q = (char *)data;
    long start = -1, stop = n - first;
    for (long i = 0; i < cnt; i++) {
      long on = strtol(q, &q, 10), oo = strtol(q, &q, 10);
      if (start >= 0) { stop = oo; break; }
      if (on == num) start = oo;
    }
    char *r = NULL;
    if (start >= 0 && first + stop <= (long)n) {
      size_t l = stop - start;
      r = malloc(l + 1);
      memcpy(r, data + first + start, l);
      r[l] = 0;
    }
    free(data);
    return r;
  }
  return NULL;
}

static long ref_num(const char *vs) { return strtol(vs, NULL, 10); }

// The object number of page INDEX (0-based) in the page tree.
long pdf_page(pdf *d, long index)
{
  char *root = pdf_object(d, d->root);
  if (!root) return -1;
  const char *vs, *ve;
  long node = dict_get(root, root + strlen(root), "Pages", &vs, &ve) ? ref_num(vs) : -1;
  free(root);
  while (node > 0) {
    char *o = pdf_object(d, node);
    if (!o) return -1;
    const char *e = o + strlen(o);
    if (!dict_get(o, e, "Kids", &vs, &ve)) { free(o); return index == 0 ? node : -1; }
    long next = -1;
    for (const char *q = vs + 1; q < ve;) {
      q = skip_ws(q, ve);
      if (*q == ']') break;
      char *r;
      long kid = strtol(q, &r, 10);
      strtol(r, &r, 10);
      q = skip_ws(r, ve) + 1;  // 'R'
      char *k = pdf_object(d, kid);
      if (!k) break;
      const char *ke = k + strlen(k), *tvs, *tve;
      long count = 1;
      if (dict_get(k, ke, "Type", &tvs, &tve) && !strncmp(tvs, "/Pages", 6)) count = dict_int(k, ke, "Count", 1);
      free(k);
      if (index < count) { next = kid; break; }
      index -= count;
    }
    free(o);
    if (next < 0) return -1;
    char *k = pdf_object(d, next);
    const char *tvs, *tve;
    int leaf = k && dict_get(k, k + strlen(k), "Type", &tvs, &tve) && !strncmp(tvs, "/Page", 5) && strncmp(tvs, "/Pages", 6);
    free(k);
    if (leaf) return next;
    node = next;
  }
  return -1;
}
