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

static int cmd_pdf(const char *exact_path, long page, const char *pass_path, const char *out_pdf, const char *out_tdl,
                   int has_dy, double dy_in)
{
  int64_t t0 = now_us();
  size_t en, pn, cn;
  unsigned char *ex = slurp(exact_path, &en), *pb = slurp(pass_path, &pn);
  if (!ex || !pb) return fail("cannot read the inputs");
  unsigned char *content = pass_content(pb, pn, &cn);
  if (!content) return fail("no content stream in the pass's output");
  pdf d = {0};
  if (pdf_open(&d, ex, en)) return fail("cannot read the exact PDF's cross-references");
  long pg = pdf_page(&d, page);
  if (pg <= 0) return fail("no such page");
  char *pd = pdf_object(&d, pg);
  const char *pe = pd + strlen(pd), *vs, *ve;
  // where the lines go: the pass's first line that is also on the exact page (an unchanged line of the paragraph)
  size_t xn = 0;
  unsigned char *xc = NULL;
  if (dict_get(pd, pe, "Contents", &vs, &ve)) {
    long cnum = ref_num(vs);
    if (cnum > 0 && d.off[cnum] >= 0) {
      const char *op = (const char *)d.b + d.off[cnum];
      xc = stream_data(&d, strstr(op, "<<"), strstr(op, "stream"), &xn);
    }
  }
  static tline pl[4096], el[8192];
  int np = text_lines(content, cn, pl, 4096), ne = xc ? text_lines(xc, xn, el, 8192) : 0;
  int placed = has_dy;
  double dy = has_dy ? dy_in : 0;  // given (the driver knows the old lines' place): no matching
  for (int i = np - 1; i >= 0 && !placed; i--)  // the pass's lines are last (earlier ones: the page above)
    for (int j = 0; j < ne; j++)
      if (strlen(pl[i].key) >= 12 && !strcmp(pl[i].key, el[j].key)) { dy = el[j].y - pl[i].y; placed = 1; break; }
  // fonts and XObjects of every page: the pass may use one this page doesn't
  size_t fl = 0, xl = 0, fcap = 1 << 16, xcap = 1 << 16;
  char *fonts = malloc(fcap), *xobjs = malloc(xcap);
  for (long i = 0;; i++) {
    long pi = pdf_page(&d, i);
    if (pi <= 0) break;
    char *o = pdf_object(&d, pi);
    const char *oe = o + strlen(o), *rs, *re;
    char *res = NULL;
    if (dict_get(o, oe, "Resources", &rs, &re)) {
      if (*rs == '<') { res = malloc(re - rs + 1); memcpy(res, rs, re - rs); res[re - rs] = 0; }
      else res = pdf_object(&d, ref_num(rs));
    }
    for (int which = 0; res && which < 2; which++) {
      const char *ks, *ke;
      if (!dict_get(res, res + strlen(res), which ? "XObject" : "Font", &ks, &ke)) continue;
      char *dict = NULL;
      if (*ks == '<') { dict = malloc(ke - ks + 1); memcpy(dict, ks, ke - ks); dict[ke - ks] = 0; }
      else dict = pdf_object(&d, ref_num(ks));
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
      memcpy(*buf + *bl, a, l);
      *bl += l;
      (*buf)[(*bl)++] = ' ';
      free(dict);
    }
    free(res);
    free(o);
  }
  fonts[fl] = 0, xobjs[xl] = 0;
  // the page's box
  double box[4] = {0, 0, 612, 792};
  for (long n = pg; n > 0;) {
    char *o = pdf_object(&d, n);
    if (!o) break;
    const char *oe = o + strlen(o), *bs, *be;
    if (dict_get(o, oe, "MediaBox", &bs, &be)) { sscanf(bs, "[ %lf %lf %lf %lf", &box[0], &box[1], &box[2], &box[3]); free(o); break; }
    n = dict_get(o, oe, "Parent", &bs, &be) ? ref_num(bs) : 0;
    free(o);
  }
  // the update: a content stream, a resources dictionary, the page (same number), an xref stream
  // the exact PDF as an APFS clone (no copy), then the update appended
  unlink(out_pdf);
  FILE *f = NULL;
  if (clonefile(exact_path, out_pdf, 0) == 0) f = fopen(out_pdf, "ab");
  if (!f) {
    f = fopen(out_pdf, "wb");
    if (f) fwrite(ex, 1, en, f);
  }
  if (!f) return fail("cannot write the PDF");
  long next = d.size > 0 ? d.size : d.nobj;
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
          d.prev_xref);
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
  free(tb.p), free(fonts), free(xobjs), free(xc), free(pd), free(content), free(ex), free(pb);
  pdf_close(&d);
  if (!wrote) return fail("cannot write the list");
  if (placed) printf("{\"ok\":true,\"page\":%ld,\"dy\":%.4f,\"us\":%lld}\n", page, dy, (long long)(now_us() - t0));
  else printf("{\"ok\":true,\"page\":%ld,\"dy\":null,\"us\":%lld}\n", page, (long long)(now_us() - t0));
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
      else if ((n == 6 || n == 7) && !strcmp(w[0], "pdf"))
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
