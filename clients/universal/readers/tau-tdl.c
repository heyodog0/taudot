// MIT. tau-tdl: a typeset page into Taudot's display list (TDL, clients/render/dlist.md), for the paragraph pass.
//
//   tau-tdl xdv DOC.xdv PASS.bin OUT.tdl
//       XeTeX: the pass's page (the last complete bop..eop in PASS.bin, the bytes the pass appended to its output),
//       drawn with the document's font definitions (DOC.xdv: the last exact output, whose pages define the fonts).
//
// Runs TeXpresso's DVI interpreter (clients/render/dvi) on Taudot's runtime (clients/render/rt, no MuPDF) and records
// with the renderer's TDL device (clients/render/dlist.c, included whole with the statics it expects), so the list
// is the one the app already draws. TeX Live files come from kpathsea (TEXMFCNF, as the engines).
//   tau-tdl pdf EXACT.pdf PAGE PASS.bin OUT.pdf OUT.tdl
//       pdfTeX, LuaTeX: the pass's lines (its content stream, in PASS.bin) on page PAGE (0-based) of the last exact
//       output: OUT.pdf is EXACT.pdf plus an incremental update in which that page draws only the pass's lines,
//       moved to where one of them is on the exact page (an unchanged line of the paragraph); OUT.tdl is a list
//       with one FIGURE op drawing that page (the drawer renders it with Core Graphics, as any included PDF).
//       "dy" in the answer is how far the lines were moved (null: no line matched; the lines stay where the pass
//       shipped them and the overlay is unplaced).
// Prints one JSON line: {"ok":true,"page":N,"ops":K,"fonts":F,"bytes":B,"us":T} or {"ok":false,"error":...}.
#include <kpathsea/kpathsea.h>
#include <stdint.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/clonefile.h>

#include "mupdf/fitz.h"
#include "mydvi.h"
#include "mydvi_interp.h"
#include "vstack.h"
#include "incdvi.h"
#include "providers.h"

// ---- what glyphs.c and dlist.c expect from txp-headless (their verbs aren't used here) ----
static fz_context *ctx;
static FILE *out;
static int dl_count;
#define MAX_PAGES 4096
static void json_str(FILE *f, const char *s, int n)  // (glyphs.c's verb writes JSON; unused here)
{
  fputc('"', f);
  for (int i = 0; i < n; i++) {
    unsigned char c = s[i];
    if (c == '"' || c == '\\') fprintf(f, "\\%c", c);
    else if (c < 0x20) fprintf(f, "\\u%04x", c);
    else fputc(c, f);
  }
  fputc('"', f);
}
static fz_display_list *page_dl(int page) { (void)page; return NULL; }
static int64_t now_us(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}
#include "../../render/glyphs.c"
#include "../../render/dlist.c"

// ---- TeX Live files: kpathsea, as the engines find them ----
const char *texlive_file_path(const char *name, FILE *record_dependency)
{
  (void)record_dependency;
  static char *last;
  free(last);
  last = NULL;
  {
    const char *ext = strrchr(name, '.');
    kpse_file_format_type fmt = kpse_tex_format;
    if (ext && !strcmp(ext, ".tfm")) fmt = kpse_tfm_format;
    else if (ext && !strcmp(ext, ".vf")) fmt = kpse_vf_format;
    else if (ext && !strcmp(ext, ".pfb")) fmt = kpse_type1_format;
    else if (ext && !strcmp(ext, ".enc")) fmt = kpse_enc_format;
    else if (ext && !strcmp(ext, ".map")) fmt = kpse_fontmap_format;
    else if (ext && (!strcmp(ext, ".otf") || !strcmp(ext, ".ttf"))) fmt = kpse_opentype_format;
    last = kpse_find_file(name, fmt, 0);
    if (!last && ext && !strcmp(ext, ".ttf")) last = kpse_find_file(name, kpse_truetype_format, 0);
  }
  return last;
}

// TeXpresso's Tectonic provider and its backtrace helper (libcommon) aren't used: TeX Live files come from kpathsea
const char *tectonic_get_file_path(const char *name) { return texlive_file_path(name, NULL); }
void print_backtrace(void) {}

static unsigned char *slurp(const char *p, size_t *n)
{
  FILE *f = fopen(p, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  *n = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *b = malloc(*n + 1);
  *n = fread(b, 1, *n, f);
  fclose(f);
  return b;
}

// The end (just past eop) of the page whose bop is at B[I], or 0.
static size_t page_end(const unsigned char *b, size_t n, size_t i, enum dvi_version v)
{
  size_t k = i;
  while (k < n) {
    int len = dvi_instr_size(b + k, n - k, v);
    if (len <= 0) return 0;
    if (b[k] == 140) return k + 1;  // eop
    k += len;
  }
  return 0;
}

static int fail(const char *m)
{
  printf("{\"ok\":false,\"error\":\"%s\"}\n", m);
  return 1;
}

static int cmd_xdv(const char *doc_path, const char *pass_path, const char *out_path, int has_dy, double dy)
{
  int64_t t0 = now_us();
  size_t dn, pn;
  unsigned char *doc = slurp(doc_path, &dn), *pass = slurp(pass_path, &pn);
  if (!doc || !pass) { free(doc); free(pass); return fail("cannot read the inputs"); }
  // the document up to its postamble (pre, every page: the font definitions) ...
  size_t cut = dn;
  for (size_t i = dn; i > 0; i--)
    if (doc[i - 1] == 248) {  // post: find it by its pointer to the last bop, checked below
      size_t k = i - 1;
      if (k + 5 <= dn) {
        uint32_t lastbop = (uint32_t)doc[k + 1] << 24 | doc[k + 2] << 16 | doc[k + 3] << 8 | doc[k + 4];
        if (lastbop < k && doc[lastbop] == 139) { cut = k; break; }
      }
    }
  // ... then the pass's page: the last bop in PASS.bin that parses to an eop and draws something
  enum dvi_version v = DVI_XDV7;
  size_t pb = 0, pe = 0;
  for (size_t i = pn; i > 0; i--)
    if (pass[i - 1] == 139) {
      size_t e = page_end(pass, pn, i - 1, v);
      if (e && e - (i - 1) > 60) { pb = i - 1, pe = e; break; }  // (60: skip an empty padding page)
    }
  if (!pe) { free(doc); free(pass); return fail("no page in the pass's output"); }
  // with everything the pass wrote before its page: the fonts it defined since the snapshot (its numbers can differ
  // from the exact output's for fonts first used after it). A pass that wrote from the very start (XeTeX had
  // flushed nothing yet) is a document by itself.
  size_t p0 = pb;
  for (size_t i = 0; i < pb; i++)
    if (pass[i] == 139 && page_end(pass, pn, i, v)) { p0 = i; break; }
  int whole = pn > 0 && pass[0] == 247;  // pre
  fz_buffer *buf = fz_new_buffer(ctx, (whole ? 0 : cut) + (pe - (whole ? 0 : p0)));
  if (whole) fz_append_data(ctx, buf, pass, pe);
  else {
    fz_append_data(ctx, buf, doc, cut);
    fz_append_data(ctx, buf, pass + p0, pe - p0);
  }
  free(doc);
  free(pass);
  // one interpreter for the process (tau-tdl serve): its resource manager keeps the fonts loaded between passes
  static incdvi_t *d;
  if (!d) d = incdvi_new(ctx, dvi_texlive_hooks(ctx, "."));
  else incdvi_reset(d);
  incdvi_update(ctx, d, buf);
  int page = incdvi_page_count(d) - 1;
  if (page < 0) { fz_drop_buffer(ctx, buf); return fail("no pages"); }
  float w, h;
  bool landscape;
  incdvi_page_dim(d, buf, page, &w, &h, &landscape);
  fz_display_list *dl = fz_new_display_list(ctx, fz_make_rect(0, 0, w, h));
  fz_device *ldev = fz_new_list_device(ctx, dl);
  incdvi_render_page(ctx, d, buf, page, ldev);
  fz_close_device(ctx, ldev);
  fz_drop_device(ctx, ldev);
  // record it as dlist.c does for a txp-render page (the ink cache stays valid: the fonts live as long as we do),
  // moved down by DY (page points): the pass's lines onto the old ones
  if (!tdl_ink) tdl_ink = fz_malloc_struct(ctx, glyph_dev);
  tdl_dev *td = new_tdl_dev();
  td->ink = tdl_ink;
  fz_rect bounds = fz_make_rect(0, 0, w, h);
  fz_run_display_list(ctx, dl, &td->base, fz_translate(0, has_dy ? (float)dy : 0), fz_infinite_rect, NULL);
  fz_close_device(ctx, &td->base);
  tdl_buf tb = {0};
  make_tdl(&tb, page, bounds, td);
  int nops = td->nops, nfonts = td->nfonts;
  free_tdl_dev(td);
  fz_drop_display_list(ctx, dl);
  fz_drop_buffer(ctx, buf);
  FILE *f = fopen(out_path, "wb");
  if (!f || fwrite(tb.p, 1, tb.n, f) != tb.n || fclose(f)) { free(tb.p); return fail("cannot write the list"); }
  free(tb.p);
  printf("{\"ok\":true,\"page\":%d,\"ops\":%d,\"fonts\":%d,\"bytes\":%zu,\"us\":%lld}\n", page, nops, nfonts, tb.n,
         (long long)(now_us() - t0));
  return 0;
}

#include "pdfmini.c"

// The pass's content: the first stream in PASS.bin that draws text, decoded.
static unsigned char *pass_content(const unsigned char *b, size_t n, size_t *cn)
{
  pdf tmp = {.b = (unsigned char *)b, .n = n};
  for (const char *p = (const char *)b; (p = memmem(p, (const char *)b + n - p, "stream", 6));) {
    const char *ds = p;
    while (ds > (const char *)b && !(ds[0] == '<' && ds[1] == '<')) ds--;
    if (p > (const char *)b + 3 && !memcmp(p - 3, "end", 3)) { p += 6; continue; }
    size_t k;
    unsigned char *c = stream_data(&tmp, ds, p, &k);
    if (c && memmem(c, k, "BT", 2)) { *cn = k; return c; }
    free(c);
    p += 6;
  }
  return NULL;
}

// Text lines of a content stream: (y of the text matrix, first 48 bytes of the line's first TJ/Tj operand).
typedef struct { double y; char key[49]; } tline;
static int text_lines(const unsigned char *c, size_t n, tline *out, int max)
{
  int k = 0;
  double ly = 0, lx = 0;
  const char *p = (const char *)c, *e = p + n;
  double num[8];
  int nn = 0;
  while (p < e && k < max) {
    p = skip_ws(p, e);
    if (p >= e) break;
    if (*p == '[' || *p == '(') {  // an operand: TJ's array or Tj's string
      const char *q = p;
      int depth = 0;
      for (; q < e; q++) {
        if (*q == '\\') { q++; continue; }
        if (*q == '(') depth++;
        else if (*q == ')') depth--;
        else if (*q == ']' && depth == 0) { q++; break; }
        if (*p == '(' && depth == 0) { q++; break; }
      }
      const char *op = skip_ws(q, e);
      if (op + 2 <= e && (!memcmp(op, "TJ", 2) || !memcmp(op, "Tj", 2))) {
        if (!k || out[k - 1].y != ly) {
          out[k].y = ly;
          size_t l = q - p < 48 ? q - p : 48;
          memcpy(out[k].key, p, l);
          out[k].key[l] = 0;
          k++;
        }
        p = op + 2;
      } else p = q;
      nn = 0;
      continue;
    }
    if ((*p >= '0' && *p <= '9') || *p == '-' || *p == '.' || *p == '+') {
      char *q;
      double v = strtod(p, &q);
      if (q == p) { p++; nn = 0; continue; }  // (a lone sign or dot: no number; strtod didn't move, and we looped)
      if (nn < 8) num[nn++] = v;
      p = q;
      continue;
    }
    const char *w = p;
    while (p < e && !strchr(" \t\r\n[]()<>/", *p)) p++;
    if (p == w) p++;
    size_t l = p - w;
    if (l == 2 && !memcmp(w, "Td", 2) && nn >= 2) lx += num[nn - 2], ly += num[nn - 1];
    else if (l == 2 && !memcmp(w, "TD", 2) && nn >= 2) lx += num[nn - 2], ly += num[nn - 1];
    else if (l == 2 && !memcmp(w, "Tm", 2) && nn >= 6) lx = num[nn - 2], ly = num[nn - 1];
    else if (l == 2 && !memcmp(w, "BT", 2)) lx = ly = 0;
    if (!(*w == '/')) nn = 0;
  }
  (void)lx;
  return k;
}

static void put(FILE *f, const char *s) { fputs(s, f); }

// The exact PDF, read once per output (a pass is drawn against the same output until the next one): its bytes,
// cross-references and the fonts and XObjects of all its pages. tau-live asks for it (`warmpdf`) when it announces the
// output, so the first pass against it doesn't wait.
typedef struct { char path[4096]; dev_t dev; ino_t ino; off_t size; struct timespec mt; unsigned char *ex; size_t en;
                 pdf d; char *fonts, *xobjs;
                 // for `page`: every (font, code) the document's pages draw, and the other resource categories
                 int scanned; uint64_t *used; size_t ucap, un; char *res[5];
                 long *pg, npg;  // every page's object number
                 int nfn; char (*fnm)[64]; int *fbpc; } exact_pdf;  // fonts' bytes per code, as looked up
static exact_pdf exc;
static int exc_hit;  // the last exact_get was served from the cache (reported in the answer)
static void exact_resources(pdf *dp, char **fonts_out, char **xobjs_out);
static exact_pdf *exact_get(const char *path)
{
  struct stat st;
  if (stat(path, &st)) return NULL;
  if (exc.ex && !strcmp(exc.path, path) && exc.dev == st.st_dev && exc.ino == st.st_ino && exc.size == st.st_size &&
      exc.mt.tv_sec == st.st_mtimespec.tv_sec && exc.mt.tv_nsec == st.st_mtimespec.tv_nsec) {
    exc_hit = 1;
    return &exc;
  }
  exc_hit = 0;
  if (exc.ex) {
    pdf_close(&exc.d);
    free(exc.ex), free(exc.fonts), free(exc.xobjs), free(exc.used), free(exc.pg), free(exc.fnm), free(exc.fbpc);
    for (int i = 0; i < 5; i++) free(exc.res[i]);
    memset(&exc, 0, sizeof exc);
  }
  size_t en;
  unsigned char *ex = slurp(path, &en);
  if (!ex) return NULL;
  if (pdf_open(&exc.d, ex, en)) { free(ex); memset(&exc, 0, sizeof exc); return NULL; }
  exc.ex = ex, exc.en = en;
  exc.npg = pdf_pages(&exc.d, &exc.pg);
  snprintf(exc.path, sizeof exc.path, "%s", path);
  exc.dev = st.st_dev, exc.ino = st.st_ino, exc.size = st.st_size, exc.mt = st.st_mtimespec;
  exact_resources(&exc.d, &exc.fonts, &exc.xobjs);
  return &exc;
}

// The fonts and XObjects of every page (the pass may use one its page doesn't), as dictionary entries
static void exact_resources(pdf *D, char **fonts_out, char **xobjs_out)
{
  size_t fl = 0, xl = 0, fcap = 1 << 16, xcap = 1 << 16;
  char *fonts = malloc(fcap), *xobjs = malloc(xcap);
  for (long i = 0; i < exc.npg; i++) {  // (D is exc.d)
    long pi = exc.pg[i];
    char *o = pdf_object(D, pi);
    if (!o) continue;
    const char *oe = o + strlen(o), *rs, *re;
    char *res = NULL;
    if (dict_get(o, oe, "Resources", &rs, &re)) {
      if (*rs == '<') { res = malloc(re - rs + 1); memcpy(res, rs, re - rs); res[re - rs] = 0; }
      else res = pdf_object(D, ref_num(rs));
    }
    for (int which = 0; res && which < 2; which++) {
      const char *ks, *ke;
      if (!dict_get(res, res + strlen(res), which ? "XObject" : "Font", &ks, &ke)) continue;
      char *dict = NULL;
      if (*ks == '<') { dict = malloc(ke - ks + 1); memcpy(dict, ks, ke - ks); dict[ke - ks] = 0; }
      else dict = pdf_object(D, ref_num(ks));
      if (!dict) continue;
      const char *a = strstr(dict, "<<"), *z = dict + strlen(dict);
      a = a ? a + 2 : dict;
      const char *zz = z;
      while (zz > a && !(zz[-1] == '>' && zz[-2] == '>')) zz--;
      if (zz > a) zz -= 2;
      size_t l = zz > a ? zz - a : 0;
      char **buf = which ? &xobjs : &fonts;
      size_t *bl = which ? &xl : &fl, *bc = which ? &xcap : &fcap;
      while (*bl + l + 2 > *bc) { *bc *= 2; *buf = realloc(*buf, *bc); }
      // each "/Name N G R" once: every page repeats the same entries (a 300-page document: thousands)
      const char *q = a, *qe = a + l;
      while (q < qe) {
        while (q < qe && (*q == ' ' || *q == '\n' || *q == '\r' || *q == '\t')) q++;
        if (q >= qe) break;
        const char *st = q, *en = NULL;
        if (*q == '/') {
          const char *r = q + 1;
          while (r < qe && !strchr(" \t\r\n/<[(", *r)) r++;
          while (r < qe && strchr(" \t\r\n", *r)) r++;
          long n1, n2;
          char R;
          int used;
          if (r < qe && sscanf(r, "%ld %ld %c%n", &n1, &n2, &R, &used) == 3 && R == 'R' && r + used <= qe) en = r + used;
        }
        if (!en) {  // anything else (an inline dictionary): the rest as it is
          memcpy(*buf + *bl, st, qe - st);
          *bl += qe - st;
          (*buf)[(*bl)++] = ' ';
          break;
        }
        size_t el = en - st;
        int dup = 0;
        for (const char *h = *buf; !dup && (h = memmem(h, *bl - (h - *buf), st, el)); h++)
          dup = (h == *buf || h[-1] == ' ') && (h + el == *buf + *bl || h[el] == ' ');
        if (!dup) {
          memcpy(*buf + *bl, st, el);
          *bl += el;
          (*buf)[(*bl)++] = ' ';
        }
        q = en;
      }
      free(dict);
    }
    free(res);
    free(o);
  }
  fonts[fl] = 0, xobjs[xl] = 0;
  *fonts_out = fonts, *xobjs_out = xobjs;
}

static int cmd_pdf(const char *exact_path, long page, const char *pass_path, const char *out_pdf, const char *out_tdl,
                   int has_dy, double dy_in)
{
  int64_t t0 = now_us();
  size_t pn, cn;
  exact_pdf *E = exact_get(exact_path);
  if (!E) return fail("cannot read the exact PDF");
  unsigned char *ex = E->ex, *pb = slurp(pass_path, &pn);
  size_t en = E->en;
  if (!pb) return fail("cannot read the inputs");
  unsigned char *content = pass_content(pb, pn, &cn);
  if (!content) { free(pb); return fail("no content stream in the pass's output"); }
  pdf *D = &E->d;
  long pg = pdf_page(D, page);
  if (pg <= 0) return fail("no such page");
  char *pd = pdf_object(D, pg);
  const char *pe = pd + strlen(pd), *vs, *ve;
  // where the lines go: the pass's first line that is also on the exact page (an unchanged line of the paragraph)
  size_t xn = 0;
  unsigned char *xc = NULL;
  int64_t t1 = now_us();
  if (!has_dy && dict_get(pd, pe, "Contents", &vs, &ve)) {  // (only to match lines: not when the driver placed them)
    long cnum = ref_num(vs);
    if (cnum > 0 && D->off[cnum] >= 0) {
      const char *op = (const char *)D->b + D->off[cnum];
      xc = stream_data(D, strstr(op, "<<"), strstr(op, "stream"), &xn);
    }
  }
  static tline pl[4096], el[8192];
  int np = has_dy ? 0 : text_lines(content, cn, pl, 4096), ne = xc ? text_lines(xc, xn, el, 8192) : 0;
  int64_t t2 = now_us();
  int placed = has_dy;
  double dy = has_dy ? dy_in : 0;  // given (the driver knows the old lines' place): no matching
  for (int i = np - 1; i >= 0 && !placed; i--)  // the pass's lines are last (earlier ones: the page above)
    for (int j = 0; j < ne; j++)
      if (strlen(pl[i].key) >= 12 && !strcmp(pl[i].key, el[j].key)) { dy = el[j].y - pl[i].y; placed = 1; break; }
  const char *fonts = E->fonts, *xobjs = E->xobjs;
  // the page's box
  double box[4] = {0, 0, 612, 792};
  for (long n = pg; n > 0;) {
    char *o = pdf_object(D, n);
    if (!o) break;
    const char *oe = o + strlen(o), *bs, *be;
    if (dict_get(o, oe, "MediaBox", &bs, &be)) { sscanf(bs, "[ %lf %lf %lf %lf", &box[0], &box[1], &box[2], &box[3]); free(o); break; }
    n = dict_get(o, oe, "Parent", &bs, &be) ? ref_num(bs) : 0;
    free(o);
  }
  // the update: a content stream, a resources dictionary, the page (same number), an xref stream
  // the exact PDF as an APFS clone (no copy), then the update appended
  int64_t t3 = now_us();
  unlink(out_pdf);
  int64_t t4 = now_us();
  FILE *f = NULL;
  if (clonefile(exact_path, out_pdf, 0) == 0) f = fopen(out_pdf, "ab");
  int64_t t5 = now_us();
  if (!f) {
    f = fopen(out_pdf, "wb");
    if (f) fwrite(ex, 1, en, f);
  }
  if (!f) return fail("cannot write the PDF");
  long next = D->size > 0 ? D->size : D->nobj;
  long a = next, r = next + 1, pp = next + 2, cat = next + 3, x = next + 4;
  long offs[5];
  if (ex[en - 1] != '\n') put(f, "\n");
  char head[128];
  int hl = snprintf(head, sizeof head, "q 1 0 0 1 0 %.4f cm\n", dy);
  offs[0] = ftell(f);
  fprintf(f, "%ld 0 obj\n<< /Length %zu >>\nstream\n%s", a, cn + hl + 3, head);
  fwrite(content, 1, cn, f);
  fprintf(f, "\nQ\nendstream\nendobj\n");
  offs[1] = ftell(f);
  fprintf(f, "%ld 0 obj\n<< /ProcSet [/PDF /Text /ImageB /ImageC /ImageI] /Font << %s>> /XObject << %s>> >>\nendobj\n", r,
          fonts, xobjs);
  offs[2] = ftell(f);
  // a one-page document: the page under a new page tree and catalog (the other pages' objects stay, unreferenced)
  fprintf(f, "%ld 0 obj\n<< /Type /Page /Parent %ld 0 R /MediaBox [%g %g %g %g]", pg, pp, box[0], box[1], box[2], box[3]);
  const char *keys[] = {"CropBox", "Rotate", NULL};
  for (int i = 0; keys[i]; i++)
    if (dict_get(pd, pe, keys[i], &vs, &ve)) fprintf(f, " /%s %.*s", keys[i], (int)(ve - vs), vs);
  fprintf(f, " /Contents %ld 0 R /Resources %ld 0 R >>\nendobj\n", a, r);
  offs[3] = ftell(f);
  fprintf(f, "%ld 0 obj\n<< /Type /Pages /Kids [%ld 0 R] /Count 1 >>\nendobj\n", pp, pg);
  offs[4] = ftell(f);
  fprintf(f, "%ld 0 obj\n<< /Type /Catalog /Pages %ld 0 R >>\nendobj\n", cat, pp);
  long xoff = ftell(f);
  enum { NO = 6 };
  unsigned char rows[NO][7];
  long nums[NO] = {a, r, pg, pp, cat, x}, offv[NO] = {offs[0], offs[1], offs[2], offs[3], offs[4], xoff};
  for (int i = 0; i < NO; i++) {
    rows[i][0] = 1;
    for (int b = 0; b < 4; b++) rows[i][1 + b] = (offv[i] >> (24 - 8 * b)) & 255;
    rows[i][5] = rows[i][6] = 0;
  }
  // /Index: the new objects in increasing order (a < r < x; pg may be anywhere)
  long order[NO] = {0, 1, 2, 3, 4, 5};
  for (int i = 0; i < NO; i++)
    for (int j = i + 1; j < NO; j++)
      if (nums[order[j]] < nums[order[i]]) { long t = order[i]; order[i] = order[j]; order[j] = t; }
  fprintf(f, "%ld 0 obj\n<< /Type /XRef /Size %ld /Root %ld 0 R /Prev %ld /W [1 4 2] /Index [", x, x + 1, cat,
          D->prev_xref);
  for (int i = 0; i < NO; i++) fprintf(f, "%ld 1 ", nums[order[i]]);
  fprintf(f, "] /Length %d >>\nstream\n", NO * 7);
  for (int i = 0; i < NO; i++) fwrite(rows[order[i]], 1, 7, f);
  fprintf(f, "\nendstream\nendobj\nstartxref\n%ld\n%%%%EOF\n", xoff);
  fclose(f);
  // the list: one FIGURE op, the updated page, in the page frame (y down)
  float w = (float)(box[2] - box[0]), h = (float)(box[3] - box[1]);
  tdl_buf tb = {0};
  tb_bytes(&tb, "TDL\0", 4);
  tb_u32(&tb, 2);
  size_t at = rec_begin(&tb, 0x01);
  tb_u32(&tb, (uint32_t)page);
  tb_f32(&tb, w);
  tb_f32(&tb, h);
  rec_end(&tb, at);
  at = rec_begin(&tb, 0x17);
  tb_f32(&tb, 0), tb_f32(&tb, 0), tb_f32(&tb, w), tb_f32(&tb, h);       // bbox
  tb_f32(&tb, 1), tb_f32(&tb, 0), tb_f32(&tb, 0), tb_f32(&tb, -1);      // PDF space -> page (y down)
  tb_f32(&tb, (float)-box[0]), tb_f32(&tb, (float)box[3]);
  for (int i = 0; i < 4; i++) tb_f32(&tb, (float)box[i]);
  tb_u32(&tb, 1);  // (the overlay's only page)
  tb_str(&tb, out_pdf);
  rec_end(&tb, at);
  at = rec_begin(&tb, 0x00);
  rec_end(&tb, at);
  FILE *g = fopen(out_tdl, "wb");
  int wrote = g && fwrite(tb.p, 1, tb.n, g) == tb.n;
  if (g && fclose(g)) wrote = 0;
  free(tb.p), free(xc), free(pd), free(content), free(pb);
  if (!wrote) return fail("cannot write the list");
  if (placed) printf("{\"ok\":true,\"page\":%ld,\"dy\":%.4f,\"cached\":%d,\"t\":[%lld,%lld,%lld,%lld,%lld,%lld],\"us\":%lld}\n", page, dy, exc_hit,
                     (long long)(t1 - t0), (long long)(t2 - t1), (long long)(t3 - t2), (long long)(t4 - t3), (long long)(t5 - t4),
                     (long long)(now_us() - t5), (long long)(now_us() - t0));
  else printf("{\"ok\":true,\"page\":%ld,\"dy\":null,\"us\":%lld}\n", page, (long long)(now_us() - t0));
  return 0;
}


// ---- page: a display page from a runner's page data, before its document is finished
//
// `page EXACT.pdf PAGE PAGE.bin OUT.pdf`: PAGE.bin holds what the engine wrote while shipping page PAGE (0-based) of a
// newer run; OUT.pdf is EXACT.pdf (a finished output) with page PAGE drawing that page's content stream instead, as an
// incremental update, every other page as it was. Only when it draws the same: every (font, code) the content shows
// is drawn somewhere in EXACT.pdf (so the font subsets there have the glyph), and every resource it names is there;
// else {"ok":false,"error":"glyph"|"resource"|...} and the caller waits for the finished document.

static const char *res_key[5] = {"ExtGState", "ColorSpace", "Pattern", "Shading", "Properties"};

static uint64_t fc_hash(const char *name, size_t nl, unsigned code)
{
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0; i < nl; i++) h = (h ^ (unsigned char)name[i]) * 1099511628211ULL;
  h = (h ^ code) * 1099511628211ULL;
  return h ? h : 1;
}
static void used_add(exact_pdf *E, uint64_t h)
{
  if (E->un * 2 >= E->ucap) {
    size_t oc = E->ucap;
    uint64_t *old = E->used;
    E->ucap = oc ? oc * 2 : 4096;
    E->used = calloc(E->ucap, sizeof *E->used);
    E->un = 0;
    for (size_t i = 0; i < oc; i++) if (old[i]) used_add(E, old[i]);
    free(old);
  }
  for (size_t i = h & (E->ucap - 1);; i = (i + 1) & (E->ucap - 1)) {
    if (E->used[i] == h) return;
    if (!E->used[i]) { E->used[i] = h; E->un++; return; }
  }
}
static int used_has(const exact_pdf *E, uint64_t h)
{
  if (!E->ucap) return 0;
  for (size_t i = h & (E->ucap - 1);; i = (i + 1) & (E->ucap - 1)) {
    if (E->used[i] == h) return 1;
    if (!E->used[i]) return 0;
  }
}
// "/Name" in a union of resource entries ("/Name ref /Name ref ...")
static int res_has(const char *u, const char *name, size_t nl)
{
  if (!u) return 0;
  for (const char *h = u; (h = strstr(h, "/")); h++)
    if (!strncmp(h + 1, name, nl) && (h[1 + nl] == ' ' || h[1 + nl] == '/' || h[1 + nl] == '<' || h[1 + nl] == '['))
      return 1;
  return 0;
}
// Bytes per code of font NAME: 2 for a Type0 (CID) font, else 1
static int font_bpc_find(exact_pdf *E, const char *name, size_t nl)
{
  for (const char *h = E->fonts; h && (h = strstr(h, "/")); h++)
    if (!strncmp(h + 1, name, nl) && h[1 + nl] == ' ') {
      long num = strtol(h + 1 + nl, NULL, 10);
      char *o = num > 0 ? pdf_object(&E->d, num) : NULL;
      int two = o && strstr(o, "Type0") != NULL;
      free(o);
      return two ? 2 : 1;
    }
  return 0;
}
static int font_bpc(exact_pdf *E, const char *name, size_t nl)  // (looked up once per name and output)
{
  if (nl >= 64) return font_bpc_find(E, name, nl);
  for (int i = 0; i < E->nfn; i++)
    if (!strncmp(E->fnm[i], name, nl) && !E->fnm[i][nl]) return E->fbpc[i];
  int b = font_bpc_find(E, name, nl);
  if (!(E->nfn & 63)) {
    E->fnm = realloc(E->fnm, (E->nfn + 64) * sizeof *E->fnm);
    E->fbpc = realloc(E->fbpc, (E->nfn + 64) * sizeof *E->fbpc);
  }
  memcpy(E->fnm[E->nfn], name, nl);
  E->fnm[E->nfn][nl] = 0;
  E->fbpc[E->nfn++] = b;
  return b;
}
static int pg_rec;  // collecting one page's (font, code)s for the scan cache (exact_scan)
static void pg_add(uint64_t h);
// One content stream: COLLECT adds its (font, code)s to E->used; else checks them and its resource names against E.
// Returns NULL when fine, else why not.
static const char *scan_content(exact_pdf *E, const unsigned char *c, size_t n, int collect)
{
  const char *p = (const char *)c, *e = p + n;
  const char *tn[3] = {0}; size_t tl[3] = {0}; int tk[3] = {0};  // the last three tokens: 1 name, 2 number, 3 other
  const char *font = NULL; size_t fl = 0; int bpc = 1;
  static char fname[256];
  while (p < e) {
    unsigned char ch = (unsigned char)*p;
    if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' || ch == '\f' || ch == 0) { p++; continue; }
    if (ch == '%') { while (p < e && *p != '\n' && *p != '\r') p++; continue; }
    int kind = 3;
    const char *ts = p;
    if (ch == '/') {
      p++;
      while (p < e && !strchr(" \t\r\n\f/<>[]()%{}", *p)) p++;
      kind = 1;
    } else if (ch == '(' || (ch == '<' && p + 1 < e && p[1] != '<')) {  // a string: the codes of the current font
      unsigned char buf[4096];
      size_t bl = 0;
      if (ch == '(') {
        int depth = 1;
        p++;
        while (p < e && depth) {
          unsigned char c2 = (unsigned char)*p++;
          if (c2 == '\\' && p < e) {
            unsigned char x = (unsigned char)*p++;
            if (x >= '0' && x <= '7') {
              int v = x - '0';
              for (int k = 0; k < 2 && p < e && *p >= '0' && *p <= '7'; k++) v = v * 8 + (*p++ - '0');
              c2 = (unsigned char)v;
            } else if (x == 'n') c2 = '\n'; else if (x == 'r') c2 = '\r'; else if (x == 't') c2 = '\t';
            else if (x == 'b') c2 = '\b'; else if (x == 'f') c2 = '\f'; else if (x == '\r' || x == '\n') continue;
            else c2 = x;
          } else if (c2 == '(') depth++;
          else if (c2 == ')' && --depth == 0) break;
          if (bl < sizeof buf) buf[bl++] = c2;
        }
      } else {
        p++;
        int hi = -1;
        while (p < e && *p != '>') {
          int v = -1;
          char x = *p++;
          if (x >= '0' && x <= '9') v = x - '0'; else if (x >= 'a' && x <= 'f') v = x - 'a' + 10;
          else if (x >= 'A' && x <= 'F') v = x - 'A' + 10;
          if (v < 0) continue;
          if (hi < 0) hi = v; else { if (bl < sizeof buf) buf[bl++] = (unsigned char)(hi * 16 + v); hi = -1; }
        }
        if (hi >= 0 && bl < sizeof buf) buf[bl++] = (unsigned char)(hi * 16);
        p++;
      }
      if (font) {
        for (size_t i = 0; i + bpc <= bl; i += bpc) {
          unsigned code = bpc == 2 ? (unsigned)buf[i] << 8 | buf[i + 1] : buf[i];
          uint64_t h = fc_hash(font, fl, code);
          if (collect) { if (pg_rec) pg_add(h); else used_add(E, h); }
          else if (!used_has(E, h)) return "glyph";
        }
      }
      kind = 3;
      ts = NULL;
    } else if (ch == '<' || ch == '>') {
      p += (p + 1 < e && p[1] == ch) ? 2 : 1;
    } else if (ch == '[' || ch == ']' || ch == '{' || ch == '}') {
      p++;
    } else if ((ch >= '0' && ch <= '9') || ch == '-' || ch == '+' || ch == '.') {
      p++;
      while (p < e && ((*p >= '0' && *p <= '9') || *p == '.')) p++;
      kind = 2;
    } else {  // an operator
      while (p < e && !strchr(" \t\r\n\f/<>[]()%{}", *p)) p++;
      size_t ol = p - ts;
#define OP(s) (ol == strlen(s) && !memcmp(ts, s, ol))
      if (OP("BI")) return "inline image";
      if (OP("Tf") && tk[1] == 1) {
        size_t l = tl[1] - 1 < sizeof fname - 1 ? tl[1] - 1 : sizeof fname - 1;
        memcpy(fname, tn[1] + 1, l);
        fname[l] = 0;
        font = fname, fl = l;
        bpc = font_bpc(E, font, fl);
        if (!bpc) { if (!collect) return "resource"; bpc = 1; }
      } else if (!collect && tk[2] == 1 && (OP("Do") || OP("gs") || OP("sh") || OP("cs") || OP("CS") || OP("scn") ||
                                           OP("SCN") || OP("DP") || OP("BDC"))) {
        const char *nm = tn[2] + 1;
        size_t nl = tl[2] - 1;
        int std = (OP("cs") || OP("CS")) && ((nl == 10 && !memcmp(nm, "DeviceGray", 10)) ||
                                             (nl == 9 && !memcmp(nm, "DeviceRGB", 9)) ||
                                             (nl == 10 && !memcmp(nm, "DeviceCMYK", 10)) ||
                                             (nl == 7 && !memcmp(nm, "Pattern", 7)));
        int found = std || res_has(OP("Do") ? E->xobjs : NULL, nm, nl);
        for (int k = 0; !found && k < 5; k++) found = res_has(E->res[k], nm, nl);
        if (!found && (OP("BDC") || OP("DP"))) found = 1;  // (a marked-content tag, not a resource)
        if (!found) return "resource";
      }
#undef OP
      kind = 3;
    }
    tn[0] = tn[1], tl[0] = tl[1], tk[0] = tk[1];
    tn[1] = tn[2], tl[1] = tl[2], tk[1] = tk[2];
    tn[2] = ts, tl[2] = ts ? (size_t)(p - ts) : 0, tk[2] = kind;
  }
  return NULL;
}
// The streams of a page's /Contents (one reference or an array of them), decoded and concatenated
static unsigned char *page_streams(pdf *D, const char *pd, size_t *cn)
{
  const char *pe = pd + strlen(pd), *vs, *ve;
  *cn = 0;
  if (!dict_get(pd, pe, "Contents", &vs, &ve)) return NULL;
  unsigned char *all = NULL;
  for (const char *q = vs; q < ve;) {
    q = skip_ws(q, ve);
    if (*q == '[' || *q == ']') { q++; continue; }
    char *r;
    long num = strtol(q, &r, 10);
    if (r == q) break;
    strtol(r, &r, 10);
    q = skip_ws(r, ve);
    if (q < ve && *q == 'R') q++;
    if (num <= 0 || num >= D->nobj || D->off[num] < 0) continue;
    const char *op = (const char *)D->b + D->off[num];
    size_t k;
    unsigned char *c = stream_data(D, strstr(op, "<<"), strstr(op, "stream"), &k);
    if (!c) continue;
    all = realloc(all, *cn + k + 1);
    memcpy(all + *cn, c, k);
    *cn += k;
    all[(*cn)++] = '\n';
    free(c);
  }
  return all;
}
// A key for a page's content: a hash of its content streams' dictionaries and raw (still compressed) bytes; 0 when
// they can't be read raw. Pages whose bytes are unchanged since the last output draw the same (font, code)s.
static uint64_t mix64(uint64_t h, const unsigned char *p, size_t n)
{
  for (; n >= 8; p += 8, n -= 8) {
    uint64_t w;
    memcpy(&w, p, 8);
    h = (h ^ w) * 0x9E3779B97F4A7C15ULL;
    h ^= h >> 29;
  }
  for (; n; p++, n--) h = (h ^ *p) * 1099511628211ULL;
  return h;
}
static uint64_t page_key(pdf *D, const char *pd)
{
  const char *pe = pd + strlen(pd), *vs, *ve;
  if (!dict_get(pd, pe, "Contents", &vs, &ve)) return 0;
  uint64_t h = 1469598103934665603ULL;
  for (const char *q = vs; q < ve;) {
    q = skip_ws(q, ve);
    if (*q == '[' || *q == ']') { q++; continue; }
    char *r;
    long num = strtol(q, &r, 10);
    if (r == q) return 0;
    strtol(r, &r, 10);
    q = skip_ws(r, ve);
    if (q < ve && *q == 'R') q++;
    if (num <= 0 || num >= D->nobj || D->off[num] < 0) return 0;
    const char *op = (const char *)D->b + D->off[num], *e = (const char *)D->b + D->n;
    const char *ds = strstr(op, "<<"), *de = ds ? strstr(ds, "stream") : NULL, *ls, *le;
    if (!de || !dict_get(ds, de, "Length", &ls, &le)) return 0;
    char *x;
    long len = strtol(ls, &x, 10);
    if (x == ls || len < 0 || *skip_ws(x, de) != '/' && *skip_ws(x, de) != '>') return 0;  // (an indirect length)
    const char *p = de + 6;
    if (*p == '\r') p++;
    if (*p == '\n') p++;
    if (p + len > e) return 0;
    h = mix64(h, (const unsigned char *)ds, de - ds);
    h = mix64(h, (const unsigned char *)p, len);
    h = (h ^ (uint64_t)len) * 1099511628211ULL;
  }
  return h ? h : 1;
}
// The (font, code)s each page drew, from the previous output, by page key; kept while the fonts' bytes per code agree
typedef struct { uint64_t key; uint64_t *hs; size_t n; } scan_ent;
static scan_ent *sc_tab, *sc_new;
static size_t sc_cap, sc_new_cap;
static uint64_t sc_sig;
static uint64_t *pg_hs, *pg_set;  // the page being scanned: its (font, code)s once each
static size_t pg_n, pg_cap, pg_setcap, *pg_slots;
static void pg_add(uint64_t h)
{
  if (pg_n * 2 >= pg_setcap) {  // (grows with the page; the set is emptied slot by slot after each page)
    size_t nc = pg_setcap ? pg_setcap * 2 : 1 << 14;
    free(pg_set), free(pg_slots);
    pg_set = calloc(nc, sizeof *pg_set), pg_slots = malloc(nc * sizeof *pg_slots), pg_setcap = nc;
    for (size_t k = 0; k < pg_n; k++) {
      size_t i = pg_hs[k] & (nc - 1);
      while (pg_set[i]) i = (i + 1) & (nc - 1);
      pg_set[i] = pg_hs[k], pg_slots[k] = i;
    }
  }
  size_t i = h & (pg_setcap - 1);
  for (; pg_set[i]; i = (i + 1) & (pg_setcap - 1)) if (pg_set[i] == h) return;
  pg_set[i] = h;
  if (pg_n == pg_cap) pg_hs = realloc(pg_hs, (pg_cap = pg_cap ? pg_cap * 2 : 4096) * sizeof *pg_hs);
  pg_slots[pg_n] = i, pg_hs[pg_n++] = h;
}
static scan_ent *sc_find(scan_ent *t, size_t cap, uint64_t key)
{
  if (!cap) return NULL;
  for (size_t i = key & (cap - 1);; i = (i + 1) & (cap - 1))
    if (!t[i].key || t[i].key == key) return &t[i];
}
static void exact_scan(exact_pdf *E)
{
  if (E->scanned) return;
  E->scanned = 1;
  // the fonts' bytes per code: a page's (font, code)s depend on them besides its bytes
  uint64_t sig = 0;
  for (const char *h = E->fonts; h && (h = strstr(h, "/")); h++) {
    size_t nl = strcspn(h + 1, " /");
    sig += fc_hash(h + 1, nl, font_bpc(E, h + 1, nl)) * 0x9E3779B97F4A7C15ULL;
    h += nl;
  }
  if (sig != sc_sig) {
    for (size_t i = 0; i < sc_cap; i++) free(sc_tab[i].hs);
    memset(sc_tab, 0, sc_cap * sizeof *sc_tab);
    sc_sig = sig;
  }
  sc_new_cap = 64;
  while (sc_new_cap < (size_t)E->npg * 2) sc_new_cap *= 2;
  sc_new = calloc(sc_new_cap, sizeof *sc_new);
  for (long i = 0; i < E->npg; i++) {
    char *o = pdf_object(&E->d, E->pg[i]);
    if (!o) break;
    uint64_t key = page_key(&E->d, o);
    scan_ent *old = key ? sc_find(sc_tab, sc_cap, key) : NULL, *nw = key ? sc_find(sc_new, sc_new_cap, key) : NULL;
    if (nw && nw->key) {  // (a page drawn twice)
    } else if (old && old->key) {
      *nw = *old;
      old->hs = NULL;
      old->key = 1;  // (a tombstone: probing goes on past it; its hs moved)
    } else {
      size_t cn;
      unsigned char *c = page_streams(&E->d, o, &cn);
      pg_n = 0, pg_rec = 1;
      if (c) scan_content(E, c, cn, 1);
      pg_rec = 0;
      if (nw) {
        nw->key = key, nw->n = pg_n;
        nw->hs = malloc((pg_n ? pg_n : 1) * sizeof *nw->hs);
        memcpy(nw->hs, pg_hs, pg_n * sizeof *pg_hs);
      }
      for (size_t k = 0; k < pg_n; k++) pg_set[pg_slots[k]] = 0;
      if (!nw) for (size_t k = 0; k < pg_n; k++) used_add(E, pg_hs[k]);
      free(c);
    }
    free(o);
  }
  for (size_t i = 0; i < sc_new_cap; i++)
    if (sc_new[i].key) for (size_t k = 0; k < sc_new[i].n; k++) used_add(E, sc_new[i].hs[k]);
  for (size_t i = 0; i < sc_cap; i++) free(sc_tab[i].hs);
  free(sc_tab);
  sc_tab = sc_new, sc_cap = sc_new_cap, sc_new = NULL;
}
// The page's content stream among what the engine wrote: the last stream with text that is no XObject, object
// stream or cross-reference stream
static unsigned char *page_content(const unsigned char *b, size_t n, size_t *cn)
{
  pdf tmp = {.b = (unsigned char *)b, .n = n};
  unsigned char *best = NULL;
  for (const char *p = (const char *)b; (p = memmem(p, (const char *)b + n - p, "stream", 6));) {
    const char *ds = p;
    while (ds > (const char *)b && !(ds[0] == '<' && ds[1] == '<')) ds--;
    if (p > (const char *)b + 3 && !memcmp(p - 3, "end", 3)) { p += 6; continue; }
    const char *de = p, *v1, *v2;
    if (dict_get(ds, de, "Subtype", &v1, &v2) || dict_get(ds, de, "Type", &v1, &v2)) { p += 6; continue; }
    size_t k;
    unsigned char *c = stream_data(&tmp, ds, p, &k);
    if (c && memmem(c, k, "BT", 2)) { free(best); best = c, *cn = k; }
    else free(c);
    p += 6;
  }
  return best;
}
static void exact_prep(exact_pdf *E)  // what `page` checks against: done at `warmpdf`, ahead of the key
{
  if (!E->res[0]) {  // the other resource categories of every page
    for (int k = 0; k < 5; k++) E->res[k] = calloc(1, 1);
    for (long i = 0; i < E->npg; i++) {
      long pi = E->pg[i];
      char *o = pdf_object(&E->d, pi);
      if (!o) continue;
      const char *oe = o + strlen(o), *rs, *re;
      char *res = NULL;
      if (dict_get(o, oe, "Resources", &rs, &re)) {
        if (*rs == '<') { res = malloc(re - rs + 1); memcpy(res, rs, re - rs); res[re - rs] = 0; }
        else res = pdf_object(&E->d, ref_num(rs));
      }
      for (int k = 0; res && k < 5; k++) {
        const char *ks, *ke;
        if (!dict_get(res, res + strlen(res), res_key[k], &ks, &ke)) continue;
        char *dict = *ks == '<' ? strndup(ks, ke - ks) : pdf_object(&E->d, ref_num(ks));
        if (!dict) continue;
        const char *a = strstr(dict, "<<"), *z = dict + strlen(dict);
        a = a ? a + 2 : dict;
        while (z > a && !(z[-1] == '>' && z[-2] == '>')) z--;
        if (z > a) z -= 2;
        size_t ol = strlen(E->res[k]), l = z > a ? z - a : 0;
        if (!strstr(E->res[k], "") || l) {
          E->res[k] = realloc(E->res[k], ol + l + 2);
          memcpy(E->res[k] + ol, a, l);
          E->res[k][ol + l] = ' ', E->res[k][ol + l + 1] = 0;
        }
        free(dict);
      }
      free(res), free(o);
    }
  }
  exact_scan(E);
}
static int cmd_page(const char *exact_path, long page, const char *bin_path, const char *out_pdf)
{
  int64_t t0 = now_us();
  exact_pdf *E = exact_get(exact_path);
  if (!E) return fail("cannot read the exact PDF");
  size_t bn, cn;
  unsigned char *b = slurp(bin_path, &bn);
  if (!b) return fail("cannot read the page's data");
  unsigned char *content = page_content(b, bn, &cn);
  free(b);
  if (!content) return fail("no content stream");
  int64_t t1 = now_us();
  exact_prep(E);
  int64_t t2 = now_us();
  pdf *D = &E->d;
  long pg = page >= 0 && page < E->npg ? E->pg[page] : -1;
  char *pd = pg > 0 ? pdf_object(D, pg) : NULL;
  if (!pd) { free(content); return fail("no such page"); }
  size_t on;  // the same content as that page's: nothing to show (the caller tries the next page)
  unsigned char *oc = page_streams(D, pd, &on);
  int same = oc && on == cn + 1 && !memcmp(oc, content, cn);
  free(oc);
  const char *why = same ? "same" : scan_content(E, content, cn, 0);
  if (why) {
    free(content), free(pd);
    printf("{\"ok\":false,\"error\":\"%s\",\"us\":%lld}\n", why, (long long)(now_us() - t0));
    return 1;
  }
  const char *pe = pd + strlen(pd), *vs, *ve;
  unlink(out_pdf);
  FILE *f = NULL;
  if (clonefile(exact_path, out_pdf, 0) == 0) f = fopen(out_pdf, "ab");
  if (!f) { f = fopen(out_pdf, "wb"); if (f) fwrite(E->ex, 1, E->en, f); }
  if (!f) { free(content), free(pd); return fail("cannot write the PDF"); }
  long next = D->size > 0 ? D->size : D->nobj;
  long a = next, r = next + 1, x = next + 2, offs[3];
  if (E->ex[E->en - 1] != '\n') put(f, "\n");
  offs[0] = ftell(f);
  fprintf(f, "%ld 0 obj\n<< /Length %zu >>\nstream\n", a, cn);
  fwrite(content, 1, cn, f);
  fprintf(f, "\nendstream\nendobj\n");
  offs[1] = ftell(f);
  fprintf(f, "%ld 0 obj\n<< /ProcSet [/PDF /Text /ImageB /ImageC /ImageI] /Font << %s>> /XObject << %s>>", r, E->fonts,
          E->xobjs);
  for (int k = 0; k < 5; k++) if (E->res[k][0]) fprintf(f, " /%s << %s>>", res_key[k], E->res[k]);
  fprintf(f, " >>\nendobj\n");
  offs[2] = ftell(f);
  fprintf(f, "%ld 0 obj\n<<", pg);  // the page, same number: its own entries but the content and the resources
  static const char *keep[] = {"Type", "Parent", "MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox", "Rotate",
                               "Annots", "Group", "UserUnit", "Tabs", "StructParents", "Metadata", NULL};
  for (int i = 0; keep[i]; i++)
    if (dict_get(pd, pe, keep[i], &vs, &ve)) fprintf(f, " /%s %.*s", keep[i], (int)(ve - vs), vs);
  fprintf(f, " /Contents %ld 0 R /Resources %ld 0 R >>\nendobj\n", a, r);
  long xoff = ftell(f);
  enum { NO = 4 };
  long nums[NO] = {a, r, pg, x}, offv[NO] = {offs[0], offs[1], offs[2], xoff};
  unsigned char rows[NO][7];
  for (int i = 0; i < NO; i++) {
    rows[i][0] = 1;
    for (int bb = 0; bb < 4; bb++) rows[i][1 + bb] = (offv[i] >> (24 - 8 * bb)) & 255;
    rows[i][5] = rows[i][6] = 0;
  }
  long order[NO] = {0, 1, 2, 3};
  for (int i = 0; i < NO; i++)
    for (int j = i + 1; j < NO; j++)
      if (nums[order[j]] < nums[order[i]]) { long t = order[i]; order[i] = order[j]; order[j] = t; }
  fprintf(f, "%ld 0 obj\n<< /Type /XRef /Size %ld /Root %ld 0 R /Prev %ld /W [1 4 2] /Index [", x, x + 1, D->root,
          D->prev_xref);
  for (int i = 0; i < NO; i++) fprintf(f, "%ld 1 ", nums[order[i]]);
  fprintf(f, "] /Length %d >>\nstream\n", NO * 7);
  for (int i = 0; i < NO; i++) fwrite(rows[order[i]], 1, 7, f);
  fprintf(f, "\nendstream\nendobj\nstartxref\n%ld\n%%%%EOF\n", xoff);
  int bad = ferror(f);
  if (fclose(f) || bad) { free(content), free(pd); return fail("cannot write the PDF"); }
  free(content), free(pd);
  printf("{\"ok\":true,\"page\":%ld,\"us\":%lld,\"t\":[%lld,%lld,%lld],\"cached\":%d,\"glyphs\":%zu}\n", page, (long long)(now_us() - t0),
         (long long)(t1 - t0), (long long)(t2 - t1), (long long)(now_us() - t2), exc_hit, E->un);
  return 0;
}

int main(int argc, char **argv)
{
  out = stdout;
  kpse_set_program_name(argv[0], "xelatex");
  ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
  if (!ctx) return fail("no context");
  fz_register_document_handlers(ctx);
  if ((argc == 5 || argc == 6) && !strcmp(argv[1], "xdv"))
    return cmd_xdv(argv[2], argv[3], argv[4], argc == 6, argc == 6 ? atof(argv[5]) : 0);
  if ((argc == 7 || argc == 8) && !strcmp(argv[1], "pdf"))
    return cmd_pdf(argv[2], atol(argv[3]), argv[4], argv[5], argv[6], argc == 8, argc == 8 ? atof(argv[7]) : 0);
  if (argc == 2 && !strcmp(argv[1], "serve")) {  // the same commands, one per line on stdin, one answer per line
    setvbuf(stdout, NULL, _IOLBF, 0);
    char line[16384];
    while (fgets(line, sizeof line, stdin)) {
      char *w[8];
      int n = 0;
      for (char *s = strtok(line, "\t\n"); s && n < 8; s = strtok(NULL, "\t\n")) w[n++] = s;
      if ((n == 4 || n == 5) && !strcmp(w[0], "xdv")) cmd_xdv(w[1], w[2], w[3], n == 5, n == 5 ? atof(w[4]) : 0);
      else if (n == 2 && !strcmp(w[0], "warm"))  // the document's own last page, drawn and dropped: every font it
        cmd_xdv(w[1], w[1], "/dev/null", 0, 0);  // defines is loaded before the first pass needs it
      else if (n == 5 && !strcmp(w[0], "page")) cmd_page(w[1], atol(w[2]), w[3], w[4]);
      else if (n == 2 && !strcmp(w[0], "warmpdf")) {  // an exact PDF read ahead of the passes drawn against it
        int64_t t0 = now_us();
        if (exact_get(w[1])) exact_prep(&exc), printf("{\"ok\":true,\"us\":%lld}\n", (long long)(now_us() - t0));
        else fail("cannot read the exact PDF");
      } else if ((n == 6 || n == 7) && !strcmp(w[0], "pdf"))
        cmd_pdf(w[1], atol(w[2]), w[3], w[4], w[5], n == 7, n == 7 ? atof(w[6]) : 0);
      else fail("bad command");
      fflush(stdout);
    }
    return 0;
  }
  fprintf(stderr, "usage: tau-tdl xdv DOC.xdv PASS.bin OUT.tdl [DY] | pdf EXACT.pdf PAGE PASS.bin OUT.pdf OUT.tdl [DY]"
                  " | serve (those commands, tab-separated, one per line;\n"
                  "  also: warm DOC.xdv, to load the document's fonts ahead of the first pass)\n");
  return 2;
}
