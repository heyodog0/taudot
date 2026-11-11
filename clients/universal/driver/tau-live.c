// MIT. tau-live: drives an UNMODIFIED TeX engine under libtau (the interposer) for live typesetting.
//
//   tau-live [--lib LIBTAU] [--snapshot-ms N] [--finish every|none] [--max-snapshots N] [--keep N]
//            DIR MAIN OUT -- ENGINE ARGS...
//
// DIR is never written: the engine runs in OUT/work, an APFS clone. Commands on stdin, events on stdout, both
// JSON lines as docs/live-protocol.md (open, change, goal, finish; hello, run, pdf, done, error), plus:
//   ["stats"]                  -> {"ev":"stats","snapshots":N,"footprint":BYTES,...}
//   ["para", path, pos, end]   -> paragraph pass (docs/universal.md)
// Docs: docs/universal.md.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <limits.h>

extern char **environ;

static int64_t now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void die(const char *m) {
  fprintf(stderr, "tau-live: %s: %s\n", m, strerror(errno));
  exit(2);
}

// ---------------------------------------------------------------------------------------------------- json

static void jstr(FILE *o, const char *s, size_t n) {
  fputc('"', o);
  for (size_t i = 0; i < n; i++) {
    unsigned char c = s[i];
    if (c == '"' || c == '\\') fprintf(o, "\\%c", c);
    else if (c == '\n') fputs("\\n", o);
    else if (c == '\t') fputs("\\t", o);
    else if (c < 0x20) fprintf(o, "\\u%04x", c);
    else fputc(c, o);
  }
  fputc('"', o);
}

typedef struct {
  int is_str;
  char *s;
  size_t n;
  long long i;
} jval;

static void put_utf8(char **w, unsigned cp) {
  char *p = *w;
  if (cp < 0x80) *p++ = cp;
  else if (cp < 0x800) *p++ = 0xc0 | cp >> 6, *p++ = 0x80 | (cp & 63);
  else if (cp < 0x10000) *p++ = 0xe0 | cp >> 12, *p++ = 0x80 | (cp >> 6 & 63), *p++ = 0x80 | (cp & 63);
  else *p++ = 0xf0 | cp >> 18, *p++ = 0x80 | (cp >> 12 & 63), *p++ = 0x80 | (cp >> 6 & 63), *p++ = 0x80 | (cp & 63);
  *w = p;
}

// Parse a JSON array of strings and integers. Returns the count, or -1.
static int jparse(const char *s, jval *v, int max) {
  int n = 0;
  while (*s == ' ') s++;
  if (*s++ != '[') return -1;
  for (;;) {
    while (*s == ' ' || *s == ',') s++;
    if (*s == ']') return n;
    if (n == max) return -1;
    if (*s == '"') {
      s++;
      size_t cap = strlen(s) + 1;
      char *buf = malloc(cap), *w = buf;
      while (*s && *s != '"') {
        if (*s != '\\') { *w++ = *s++; continue; }
        s++;
        char c = *s++;
        if (c == 'n') *w++ = '\n';
        else if (c == 't') *w++ = '\t';
        else if (c == 'r') *w++ = '\r';
        else if (c == 'b') *w++ = '\b';
        else if (c == 'f') *w++ = '\f';
        else if (c == 'u') {
          unsigned cp = 0;
          sscanf(s, "%4x", &cp);
          s += 4;
          if (cp >= 0xd800 && cp < 0xdc00 && s[0] == '\\' && s[1] == 'u') {
            unsigned lo = 0;
            sscanf(s + 2, "%4x", &lo);
            s += 6;
            cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
          }
          put_utf8(&w, cp);
        } else *w++ = c;
      }
      if (*s != '"') { free(buf); return -1; }
      s++;
      *w = 0;  // (strcmp'd as commands and used as paths: a buffer as long as the rest of the line may be reused memory)
      v[n++] = (jval){1, buf, (size_t)(w - buf), 0};
    } else {
      char *e;
      long long x = strtoll(s, &e, 10);
      if (e == s) return -1;
      s = e;
      v[n++] = (jval){0, NULL, 0, x};
    }
  }
}

// ---------------------------------------------------------------------------------------------------- state

typedef struct {
  char *rel;
  long ext;
} extent;

typedef struct {
  pid_t pid;
  int seq;
  int64_t t;
  int n;
  extent *e;
  char *cur;     // the file being read when it was taken, and where (a line start)
  long cur_pos;
  pid_t warm;    // its warm pass, parked (0: none)
  int pages;     // pages shipped before it
} snap;

typedef struct {
  char *rel;
  char *data;
  size_t len, cap;
  int dirty;  // the clone's copy is behind: written by flush_texts, after the warm pass is on its way
  long lc_pos;  // a known line start: offset lc_pos is on line lc_line (kept across edits, so typing counts little)
  int lc_line;
} text;
// The line of offset END (1-based), counted from the nearest known point
static int line_of(text *t, long end) {
  if (end > (long)t->len) end = (long)t->len;
  if (t->lc_line < 1 || t->lc_pos > (long)t->len) t->lc_pos = 0, t->lc_line = 1;
  long p = t->lc_pos;
  int l = t->lc_line;
  if (end >= p) { for (; p < end; p++) l += t->data[p] == '\n'; }
  else { for (; p > end; p--) l -= t->data[p - 1] == '\n'; }
  t->lc_pos = end, t->lc_line = l;
  return l;
}

static char dir[2048], work[2048], tdir[2048], outdir[2048], lib[2048], mainf[1024];
static char **eng_argv;
static int msg_r = -1, msg_w = -1, life_r = -1, life_w = -1;
static long snapshot_ms = 20;  // as pdftex-live --serve
static long first_sparse_ms = 200;  // a first run with no .aux (spawn_engine)
// Display pages (pdf engines): the run's first page after an edit, drawn on the last finished output (tau-tdl page)
static int display_pages = 1;
static int first_finish = 1;  // a fresh run finishes once at the goal page (else the first), at once
static char last_exact[4600];  // the newest finished PDF, and its page count
static int last_exact_pages;
static int pdf_out_seq = -1, pdf_out_run = -1;  // the last pdf event's (a display page after it is of no use)
static int display_seq = -1;  // the edit whose display page went out (or was given up)
// The display page is the first page the run ships that differs from the last finished PDF's: TeX may have set the
// page after the resume point before it read the edited line, or the run resumed pages before the edit (those are
// unchanged); up to DISPLAY_TRIES pages
static int disp_wait = -1;  // the edit whose page request is with the reader
// The pages shipped and not yet asked about, in order (every one: the display page is the first that changed, and the
// pages before it in the display PDF must be unchanged). Held while the edit's paragraph pass runs: the preview first.
static int dq_seq = -1, dq_n, dq_at;
static int dq_c[64];
static char dq_path[64][2048];
static void display_pump(void);
enum { DISPLAY_TRIES = 64 };  // (the resume snapshot may be pages before the edit: they are spaced on long documents)
static char **park_argv;              // the engine's command line in the parked form (--park, --parked)
static char park_sig[32], park_sock[1024], parked_sock[1024];
static uint64_t fnv1a(uint64_t h, const void *p, size_t n) {
  for (size_t i = 0; i < n; i++) h = (h ^ ((const unsigned char *)p)[i]) * 1099511628211ULL;
  return h;
}
static const char *job_stem(void);
static const char *out_ext(void);
static int exists(const char *p);
static int finish_every = 0, max_snaps = 256, hook = 0;
static long dense = 300;
static int para = 1;    // a paragraph pass beside the exact pass (with --hook)

// The end of K's paragraph in T: the start of the next blank line or structural line (or the end).
static int structural(const char *l, const char *e) {
  while (l < e && (*l == ' ' || *l == '\t')) l++;
  if (l >= e || *l == '\n') return 1;
  static const char *w[] = {"\\begin", "\\end", "\\section", "\\subsection", "\\subsubsection", "\\paragraph",
                            "\\item", "\\caption", "\\par", "\\[", "$$", "\\chapter", "\\bibliography", 0};
  for (int i = 0; w[i]; i++)
    if ((size_t)(e - l) >= strlen(w[i]) && !strncmp(l, w[i], strlen(w[i]))) return 1;
  return 0;
}
static long para_end(const text *t, long k) {
  const char *d = t->data, *e = d + t->len;
  const char *l = memchr(d + k, '\n', t->len - k);
  while (l && l + 1 < e) {
    if (structural(l + 1, e)) return l + 1 - d;
    l = memchr(l + 1, '\n', e - l - 1);
  }
  return t->len;
}  // bytes before the edit with a snapshot at every line
static snap *snaps;
static int nsnaps, capsnaps;
static pid_t runner = -1, root = -1;
static pid_t fins[256];
static int nfins;
static int seq, applied, applied_at_run;
static int64_t t_apply;
static int run_open = 0;  // a run is going (no E yet)
static int pages_now, from_page;
static text *texts;
static int ntexts;
static int fresh_runs;
static const char *engine_path;
static FILE *dbg;
static int run_no = 1, max_runs = 5;          // latexmk's rule: runs in this compile, and at most
static char bibtex_bin[2048], biber_bin[2048], makeindex_bin[2048], state_dir[2048];
static char *bib_state;                        // the bib lines BibTeX last ran on (NULL: never)
static unsigned long bib_hash_last;            // the .bib files' hash then
static char blg_this[4200];                    // BibTeX's log, if it ran in this compile
static int64_t t_fin_start[65536];             // a finisher's fork time (by pid & 0xffff), for finish_us
static int nfetch;

// XeTeX's pages as PDF (tau-pdfmx serve: xdvipdfmx kept resident, beside tau-live). A `pdf` event of an XDV goes out
// when its pages are converted, with `pdf_path` (pages `pdf_first`..`pages`-1, as `xdvipdfmx -s` makes them). Events
// after it wait behind it so the order is kept; `para` events don't (the preview is independent of the pages).
static pid_t pdfmx = -1;
static int pdfmx_in = -1, pdfmx_out = -1;
static char pdfmx_bin[2048];
typedef struct { char *s; size_t n; int pending, first, last; int64_t t_sent; char pdf[4600]; } oq_ent;
static oq_ent oq[64];
static int noq;
static FILE *oq_tail;  // events written after the last pending one
static char *oq_tail_s;
static size_t oq_tail_n;
static FILE *ev_out(void) {
  if (!noq) return stdout;
  if (!oq_tail) oq_tail = open_memstream(&oq_tail_s, &oq_tail_n);
  return oq_tail;
}
#define EVO ev_out()
static void oq_flush(void) {
  while (noq && !oq[0].pending) {
    fwrite(oq[0].s, 1, oq[0].n, stdout);
    free(oq[0].s);
    memmove(oq, oq + 1, --noq * sizeof *oq);
  }
  if (!noq && oq_tail) {
    fclose(oq_tail);
    fwrite(oq_tail_s, 1, oq_tail_n, stdout);
    free(oq_tail_s);
    oq_tail = NULL, oq_tail_s = NULL, oq_tail_n = 0;
  }
  fflush(stdout);
}
// What the client has of an XDV document's pages: per page, a hash of its bytes (bop up to the next bop or the
// postamble, without bop's back pointer, which moves when an earlier page changes length); and what every page's
// conversion depends on besides: page 1 (xdvipdfmx reads its specials, e.g. the paper size, for every page), the
// units, and the font definitions, which xdvipdfmx takes from the postamble by number. A page whose bytes are the
// same, in a document whose page 1 and units are the same and whose fonts have the same definitions under the same
// numbers (an early output lists fewer: only those defined so far), converts to the same PDF page.
typedef struct { int np, nf; uint64_t *hs, base; uint32_t *fid; uint64_t *fh; } xdv_info;
static xdv_info dlvx;  // the font definitions the client's pages were made with (all outputs since a change)
static uint64_t *dlv;
static int ndlv, capdlv;
static void xdv_free(xdv_info *x) { free(x->hs), free(x->fid), free(x->fh); memset(x, 0, sizeof *x); }
// Every font number defined in both with the same definition
static int fonts_agree(const xdv_info *a, const xdv_info *b) {
  for (int i = 0; i < a->nf; i++)
    for (int j = 0; j < b->nf; j++)
      if (a->fid[i] == b->fid[j] && a->fh[i] != b->fh[j]) return 0;
  return 1;
}
static uint64_t fnv(uint64_t h, const unsigned char *p, size_t n) {
  for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ULL;
  return h;
}
static uint32_t be32(const unsigned char *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
// An XDV's page hashes, document hash (page 1, units) and fonts; returns the page count, or -1
static int xdv_hashes(const char *path, xdv_info *x) {
  memset(x, 0, sizeof *x);
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  struct stat st;
  if (fstat(fd, &st) || st.st_size < 64) { close(fd); return -1; }
  size_t n = st.st_size;
  const unsigned char *b = mmap(NULL, n, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (b == MAP_FAILED) return -1;
  int np = -1;
  size_t i = n - 1;
  while (i > 0 && b[i] == 223) i--;
  if (i < 5 || b[i - 5] != 249) goto out;  // post_post q[4] id
  size_t post = be32(b + i - 4), pp = i - 5;
  if (post + 29 > pp || b[post] != 248) goto out;
  size_t cap = 64, k = 0, *bop = malloc(cap * sizeof *bop);
  for (uint32_t q = be32(b + post + 1); q != 0xffffffffu; q = be32(b + q + 41)) {
    if (q + 45 > post || b[q] != 139 || k > 1000000) { free(bop); goto out; }
    if (k == cap) bop = realloc(bop, (cap *= 2) * sizeof *bop);
    bop[k++] = q;
  }
  x->hs = malloc((k ? k : 1) * sizeof *x->hs);
  for (size_t j = 0; j < k; j++) {  // (bop[] is last page first)
    size_t a = bop[k - 1 - j], z = j + 1 < k ? bop[k - 2 - j] : post;
    uint64_t h = fnv(14695981039346656037ULL, b + a, 41);
    x->hs[j] = fnv(h, b + a + 45, z - a - 45);
  }
  free(bop);
  x->base = fnv(fnv(14695981039346656037ULL, b + post + 5, 12), (unsigned char *)x->hs, k ? 8 : 0);
  // the postamble's font definitions: fnt_def1..4 (TFM) and XeTeX's native ones (dvi.c's layout)
  int capf = 0;
  for (size_t q = post + 29; q < pp;) {
    unsigned op = b[q];
    size_t z;
    uint32_t id;
    if (op >= 243 && op <= 246) {
      unsigned w = op - 242;
      if (q + 1 + w + 14 > pp) goto bad;
      id = 0;
      for (unsigned m = 0; m < w; m++) id = id << 8 | b[q + 1 + m];
      z = q + 1 + w + 14 + b[q + 1 + w + 12] + b[q + 1 + w + 13];
    } else if (op == 252) {
      if (q + 12 > pp) goto bad;
      id = be32(b + q + 1);
      unsigned fl = b[q + 9] << 8 | b[q + 10];
      z = q + 12 + b[q + 11] + 4;
      z += 4 * (!!(fl & 0x200) + !!(fl & 0x1000) + !!(fl & 0x2000) + !!(fl & 0x4000));
    } else {
      goto bad;
    }
    if (z > pp) goto bad;
    if (x->nf == capf) {
      capf = capf ? capf * 2 : 64;
      x->fid = realloc(x->fid, capf * sizeof *x->fid), x->fh = realloc(x->fh, capf * sizeof *x->fh);
    }
    x->fid[x->nf] = id, x->fh[x->nf++] = fnv(14695981039346656037ULL, b + q, z - q);
    q = z;
  }
  np = x->np = (int)k;
  goto out;
bad:
  xdv_free(x);
out:
  munmap((void *)b, n);
  return np;
}

static void pdfmx_start(void) {
  int a[2], b[2];
  if (access(pdfmx_bin, X_OK) || pipe(a) || pipe(b)) return;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, a[0], 0);
  posix_spawn_file_actions_adddup2(&fa, b[1], 1);
  posix_spawn_file_actions_addclose(&fa, a[1]);
  posix_spawn_file_actions_addclose(&fa, b[0]);
  char lg[4200];
  snprintf(lg, sizeof lg, "%s/pdfmx.log", tdir);
  posix_spawn_file_actions_addopen(&fa, 2, lg, O_WRONLY | O_CREAT | O_APPEND, 0644);
  char *av[] = {pdfmx_bin, "serve", NULL};
  if (posix_spawn(&pdfmx, pdfmx_bin, &fa, NULL, av, environ)) pdfmx = -1;
  posix_spawn_file_actions_destroy(&fa);
  close(a[0]), close(b[1]);
  if (pdfmx < 0) { close(a[1]), close(b[0]); return; }
  pdfmx_in = a[1], pdfmx_out = b[0];
  fcntl(pdfmx_in, F_SETFD, FD_CLOEXEC), fcntl(pdfmx_out, F_SETFD, FD_CLOEXEC);
}
static void pdfmx_answer(const char *l);
static void pdfmx_stop(void) {
  if (pdfmx > 0) { kill(pdfmx, SIGKILL); waitpid(pdfmx, NULL, 0); }
  if (pdfmx_in >= 0) close(pdfmx_in);
  if (pdfmx_out >= 0) close(pdfmx_out);
  pdfmx = -1, pdfmx_in = pdfmx_out = -1;
  for (int i = 0; i < noq; i++)
    if (oq[i].pending) pdfmx_answer("done -1 0");  // their events go out without pdf_path
}
// The event completed: with pdf_path (pages pdf_first..pdf_last; every other page as the client has it) or, if the
// conversion failed, pdf_error (the client converts the XDV itself; the next event converts everything again)
static void pdfmx_answer_ent(oq_ent *e, int code) {
  char *s = NULL;
  size_t n = 0;
  FILE *f = open_memstream(&s, &n);
  fwrite(e->s, 1, e->n, f);
  if (!code) {
    if (e->last >= e->first) { fputs(",\"pdf_path\":", f); jstr(f, e->pdf, strlen(e->pdf)); }
    fprintf(f, ",\"pdf_first\":%d,\"pdf_last\":%d", e->first, e->last);
  } else {
    fprintf(f, ",\"pdf_error\":%d", code);
    ndlv = 0;
  }
  fprintf(f, ",\"pdfmx_us\":%lld}\n", (long long)(now_us() - e->t_sent));
  fclose(f);
  free(e->s);
  e->s = s, e->n = n, e->pending = 0;
  oq_flush();
}
// An answer from tau-pdfmx: for the oldest pending event
static void pdfmx_answer(const char *l) {
  int i = 0, code = -1;
  long long us = 0;
  while (i < noq && !oq[i].pending) i++;
  if (i == noq) return;
  sscanf(l, "done %d %lld", &code, &us);
  if (dbg) fprintf(dbg, "pdfmx: pages %d-%d code %d, %lld us in the converter\n", oq[i].first, oq[i].last, code, us), fflush(dbg);
  pdfmx_answer_ent(&oq[i], code);
}


static void emit(const char *fmt, ...) {
  va_list a;
  va_start(a, fmt);
  vfprintf(EVO, fmt, a);
  va_end(a);
  fputc('\n', EVO);
  fflush(EVO);
}

static text *get_text(const char *rel) {
  for (int i = 0; i < ntexts; i++)
    if (!strcmp(texts[i].rel, rel)) return &texts[i];
  texts = realloc(texts, (ntexts + 1) * sizeof *texts);
  text *t = &texts[ntexts++];
  t->rel = strdup(rel);
  t->data = NULL;
  t->len = t->cap = 0;
  t->dirty = 0;
  t->lc_pos = 0, t->lc_line = 1;
  char p[4096];
  snprintf(p, sizeof p, "%s/%s", work, rel);
  FILE *f = fopen(p, "rb");
  if (f) {
    fseek(f, 0, SEEK_END);
    t->len = ftell(f);
    fseek(f, 0, SEEK_SET);
    t->data = malloc(t->len + 1);
    t->cap = t->len + 1;
    t->len = fread(t->data, 1, t->len, f);
    fclose(f);
  }
  return t;
}

static void write_file(const char *path, const char *data, size_t len) {
  char tmp[4096];
  snprintf(tmp, sizeof tmp, "%s.tau-tmp", path);
  FILE *f = fopen(tmp, "wb");
  if (!f) die(path);
  fwrite(data, 1, len, f);
  fclose(f);
  rename(tmp, path);
}

static void read_extents(snap *s) {
  char p[4096], line[4096];
  snprintf(p, sizeof p, "%s/s-%d", tdir, s->pid);
  FILE *f = fopen(p, "r");
  s->n = 0;
  s->e = NULL;
  s->cur = NULL;
  s->cur_pos = -1;
  s->warm = 0;
  s->pages = 0;
  if (!f) return;
  int cap = 0;
  while (fgets(line, sizeof line, f)) {
    long ext;
    int off0;
    int pg;
    if (sscanf(line, "P %d", &pg) == 1 && line[0] == 'P') { s->pages = pg; continue; }
    if (sscanf(line, "C %ld %n", &ext, &off0) == 1) {
      line[strcspn(line, "\n")] = 0;
      s->cur = strdup(line + off0);
      s->cur_pos = ext;
      continue;
    }
    int wr, miss, off;
    if (sscanf(line, "%ld %d %d %n", &ext, &wr, &miss, &off) < 3) continue;
    line[strcspn(line, "\n")] = 0;
    (void)wr;  // (an .aux is read, then written: its read extent counts for reruns)
    if (s->n == cap) s->e = realloc(s->e, (cap = cap ? cap * 2 : 16) * sizeof *s->e);
    s->e[s->n++] = (extent){strdup(line + off), ext};
  }
  fclose(f);
  unlink(p);
}

static long snap_extent(snap *s, const char *rel) {
  for (int i = 0; i < s->n; i++)
    if (!strcmp(s->e[i].rel, rel)) return s->e[i].ext;
  return 0;
}

// Processes an edit supersedes (snapshots past the resume point, the old runner and finishers, stopped), killed once
// the paragraph preview is out: tearing down dozens of large processes (a long document has many) while the warm pass
// wakes and the reader writes held both up by ms (wake 1.4 ms, reader 6 ms at 300 pages). Parked or stopped, they
// cost nothing meanwhile.
static pid_t doomed[8192];
static int ndoomed;
static int64_t doomed_at;
static void kill_doomed(void) {
  for (int i = 0; i < ndoomed; i++) kill(doomed[i], SIGKILL);
  ndoomed = 0;
}
static void doom(pid_t p) {
  if (p <= 0) return;
  if (ndoomed == (int)(sizeof doomed / sizeof *doomed)) kill_doomed();
  if (!ndoomed) doomed_at = now_us();
  doomed[ndoomed++] = p;
}
static void free_snap_later(snap *s) {
  doom(s->pid);
  if (s->warm > 0) doom(s->warm);
  for (int i = 0; i < s->n; i++) free(s->e[i].rel);
  free(s->e);
  free(s->cur);
}
static void free_snap(snap *s) {
  if (s->warm > 0) kill(s->warm, SIGKILL);
  for (int i = 0; i < s->n; i++) free(s->e[i].rel);
  free(s->e);
  free(s->cur);
}

static void kill_fins(void) {
  for (int i = 0; i < nfins; i++) kill(fins[i], SIGKILL);
  nfins = 0;
}

static void kill_all(void) {
  kill_doomed();
  kill_fins();
  if (runner > 0) kill(runner, SIGKILL);
  for (int i = 0; i < nsnaps; i++) { kill(snaps[i].pid, SIGKILL); free_snap(&snaps[i]); }
  nsnaps = 0;
  runner = -1;
}

// A session's engine forked from a parked one (tau-live --park): the session's environment (its TAU_ variables), the
// work directory and the main file's name go over the socket with the message pipe, the lifeline and the log. -1: no
// parked engine there, or one started differently (its signature): the caller spawns as usual.
static pid_t from_parked(char **env, const char *logp) {
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un a = {0};
  a.sun_family = AF_UNIX;
  snprintf(a.sun_path, sizeof a.sun_path, "%s", parked_sock);
  if (s < 0 || connect(s, (struct sockaddr *)&a, sizeof a)) { if (s >= 0) close(s); return -1; }
  char mn[4300];
  snprintf(mn, sizeof mn, "%s/main-name", tdir);
  char line[1100];
  int ll = snprintf(line, sizeof line, "%s\n", mainf);
  write_file(mn, line, ll);
  static char req[1 << 15];
  size_t n = (size_t)snprintf(req, sizeof req, "sig %s\ncwd %s\nTAU_MAIN_NAME=%s\n", park_sig, work, mn);
  for (int i = 0; env[i]; i++)
    if (!strncmp(env[i], "TAU_", 4) && strncmp(env[i], "TAU_FD=", 7) && strncmp(env[i], "TAU_LIFE=", 9) && n < sizeof req)
      n += (size_t)snprintf(req + n, sizeof req - n, "%s\n", env[i]);
  if (n >= sizeof req - 1) { close(s); return -1; }
  req[n++] = 0;
  int lg = open(logp, O_WRONLY | O_CREAT | O_APPEND, 0644);
  int fdv[3] = {msg_w, life_r, lg};
  struct msghdr m = {0};
  struct iovec io = {req, n};
  char cbuf[CMSG_SPACE(sizeof fdv)];
  memset(cbuf, 0, sizeof cbuf);
  m.msg_iov = &io, m.msg_iovlen = 1, m.msg_control = cbuf, m.msg_controllen = sizeof cbuf;
  struct cmsghdr *h = CMSG_FIRSTHDR(&m);
  h->cmsg_level = SOL_SOCKET, h->cmsg_type = SCM_RIGHTS, h->cmsg_len = CMSG_LEN(sizeof fdv);
  memcpy(CMSG_DATA(h), fdv, sizeof fdv);
  ssize_t w = sendmsg(s, &m, 0);
  close(lg);
  pid_t pid = -1;
  if (w == (ssize_t)n) {
    char b[32] = {0};
    ssize_t r = read(s, b, sizeof b - 1);
    if (r > 0) pid = atoi(b);
  }
  close(s);
  return pid > 0 ? pid : -1;
}

static void spawn_engine(void) {
  kill_all();
  char e1[4200], e2[4200], e3[64], e4[64], e5[64], e6[4200], e7[4200];
  snprintf(e1, sizeof e1, "TAU_PROJECT=%s", work);
  snprintf(e2, sizeof e2, "TAU_OUT=%s", tdir);
  snprintf(e3, sizeof e3, "TAU_FD=%d", msg_w);
  snprintf(e4, sizeof e4, "TAU_LIFE=%d", life_r);
  // a first run with no .aux is always followed by reruns that typeset the body again (their snapshots replace its
  // own): it snapshots sparsely, and at the \begin{document} line, where those reruns resume (the .aux, the .out)
  char e8[1200] = "";
  char auxp[4300];
  snprintf(auxp, sizeof auxp, "%s/%s.aux", work, job_stem());
  long sms = snapshot_ms;
  if (first_sparse_ms > snapshot_ms && fresh_runs == 0 && !exists(auxp)) {
    text *t = get_text(mainf);
    const char *b = t->data ? memmem(t->data, t->len, "\\begin{document}", 16) : NULL;
    if (b) {
      long at = b - t->data, ls = at;
      while (ls > 0 && t->data[ls - 1] != '\n') ls--;
      snprintf(e8, sizeof e8, "TAU_MARK=%s %ld %ld", mainf, ls, at + 1);
      sms = first_sparse_ms;
    }
  }
  snprintf(e5, sizeof e5, "TAU_SNAPSHOT_MS=%ld", sms);
  snprintf(e6, sizeof e6, "DYLD_INSERT_LIBRARIES=%s", lib);
  snprintf(e7, sizeof e7, "TAU_ZCACHE=%s/zcache", outdir);
  int n = 0;
  while (environ[n]) n++;
  char **env = calloc(n + 16, sizeof *env);
  int k = 0;
  for (int i = 0; i < n; i++)
    if (strncmp(environ[i], "TAU_PROJECT=", 12) && strncmp(environ[i], "TAU_OUT=", 8) &&
        strncmp(environ[i], "TAU_FD=", 7) && strncmp(environ[i], "TAU_LIFE=", 9) &&
        strncmp(environ[i], "TAU_SNAPSHOT_MS=", 16) && strncmp(environ[i], "TAU_ZCACHE=", 11) &&
        strncmp(environ[i], "TAU_MARK=", 9))
      env[k++] = environ[i];
  env[k++] = e1, env[k++] = e2, env[k++] = e3, env[k++] = e4, env[k++] = e5, env[k++] = e6, env[k++] = e7;
  if (finish_every) env[k++] = "TAU_FINISH=every";
  if (e8[0]) env[k++] = e8;
  if (display_pages && hook && !strcmp(out_ext(), "pdf")) env[k++] = "TAU_PAGE_PREVIEW=1";
  if (first_finish) env[k++] = "TAU_FIRST_FINISH=1";  // the goal page (else the first) out as soon as it ships
  env[k] = NULL;
  char logp[4096];
  snprintf(logp, sizeof logp, "%s/engine.out", tdir);
  pid_t pk = parked_sock[0] ? from_parked(env, logp) : -1;
  if (pk > 0) {
    root = pk;
  } else {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 1, logp, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_adddup2(&fa, 1, 2);
    posix_spawn_file_actions_addchdir(&fa, work);
    if (posix_spawn(&root, eng_argv[0], &fa, NULL, eng_argv, env)) die("spawn engine");
    posix_spawn_file_actions_destroy(&fa);
  }
  if (dbg) fprintf(dbg, "%lld engine %d %s\n", (long long)now_us(), root, pk > 0 ? "from the parked engine" : "spawned"), fflush(dbg);
  free(env);
  runner = root;
  run_open = 1;
  fresh_runs++;
  pages_now = 0;
  from_page = 0;
}

// ---------------------------------------------------------------------------------------------------- paragraph preview

#include "synctex.c"

// Each edit's newline count change, so a paragraph's line in an older output's text can be found
typedef struct { int applied; char rel[512]; long pos; int nl; } edit_rec;
static edit_rec erecs[1024];
static int nerecs;
static void note_edit(const char *rel, long pos, int nl) {
  edit_rec *e = &erecs[nerecs++ % 1024];
  e->applied = applied, e->pos = pos, e->nl = nl;
  snprintf(e->rel, sizeof e->rel, "%s", rel);
}
// The outputs announced lately (the newest that shows the paragraph's old lines is the one the preview goes on)
typedef struct { char path[4600], sx[4600]; int applied; } out_rec;
static out_rec outs[8];
static int nouts;
static sx_index sxs[8];
static void old_lines(sx_index **xp, sx_para *op, out_rec **srcp);
// The paragraph's old lines all start at the same x (a list item's are all indented alike; a hanging indent's aren't)
static int same_left(const sx_index *x, const sx_para *o) {
  const sx_rec *r1 = &x->r[o->first];
  for (int i = o->first + 1, k = 1; i < x->n && k < o->n; i++)
    if (x->r[i].parent == r1->parent) {
      if (x->r[i].h != r1->h) return 0;
      k++;
    }
  return 1;
}
// The pass in flight: what it typesets, for its event
static struct { int seq; char rel[512]; long end; int line; } pass;
// The reader (tau-tdl serve): one process, requests in order, one answer line each
static pid_t reader = -1;
static int reader_in = -1, reader_out = -1;
static char tdl_bin[2048];
typedef struct { char *head; int seq; int64_t t_sent; int pdf; int page; } reader_job;  // (page: a display page)
static reader_job jobs[16];
static int njobs;
static int npreviews;
static void reader_start(void) {
  int a[2], b[2];
  if (access(tdl_bin, X_OK) || pipe(a) || pipe(b)) return;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, a[0], 0);
  posix_spawn_file_actions_adddup2(&fa, b[1], 1);
  posix_spawn_file_actions_addclose(&fa, a[1]);
  posix_spawn_file_actions_addclose(&fa, b[0]);
  char lg[4200];  // (the DVI interpreter talks on stderr)
  snprintf(lg, sizeof lg, "%s/reader.log", tdir);
  posix_spawn_file_actions_addopen(&fa, 2, lg, O_WRONLY | O_CREAT | O_APPEND, 0644);
  char *av[] = {tdl_bin, "serve", NULL};
  extern char **environ;
  if (posix_spawn(&reader, tdl_bin, &fa, NULL, av, environ)) reader = -1;
  posix_spawn_file_actions_destroy(&fa);
  close(a[0]), close(b[1]);
  if (reader < 0) { close(a[1]), close(b[0]); return; }
  reader_in = a[1], reader_out = b[0];
  fcntl(reader_in, F_SETFD, FD_CLOEXEC), fcntl(reader_out, F_SETFD, FD_CLOEXEC);
}
static void reader_stop(void) {
  if (reader > 0) { kill(reader, SIGKILL); waitpid(reader, NULL, 0); }
  if (reader_in >= 0) close(reader_in);
  if (reader_out >= 0) close(reader_out);
  reader = -1, reader_in = reader_out = -1;
  for (int i = 0; i < njobs; i++) free(jobs[i].head);
  njobs = 0;
}

// ---------------------------------------------------------------------------------------------------- edits

typedef struct {
  char *rel;
  long k;  // first changed byte
} change;

static void drop_deferred(void);
static void flush_texts(void);
static void apply_run(change *ch, int nch, const char *why, int rerun);
static void apply(change *ch, int nch, const char *why) { apply_run(ch, nch, why, 0); }
static void apply_run(change *ch, int nch, const char *why, int rerun) {
  if (rerun) run_no++;
  else { seq++; run_no = 1; blg_this[0] = 0; }
  drop_deferred();
  if (!rerun) applied_at_run = applied;
  t_apply = now_us();
  for (int i = 0; i < nfins; i++) { kill(fins[i], SIGSTOP); doom(fins[i]); }  // (stopped now, killed after the
  nfins = 0;                                                                    // preview: kill_doomed)
  int best = -1;
  for (int i = nsnaps - 1; i >= 0 && best < 0; i--) {
    int ok = 1;
    for (int c = 0; c < nch && ok; c++)
      if (snap_extent(&snaps[i], ch[c].rel) > ch[c].k) ok = 0;
    if (ok) best = i;
  }
  if (best < 0) {
    flush_texts();
    spawn_engine();
    emit("{\"ev\":\"run\",\"seq\":%d,\"run\":%d,\"applied\":%d,\"why\":\"%s\",\"from_page\":0,\"fresh\":true}", seq,
         run_no, applied_at_run, why);
    return;
  }
  if (runner > 0) { kill(runner, SIGSTOP); doom(runner); }
  runner = -1;
  long next_ext = best + 1 < nsnaps && nch ? snap_extent(&snaps[best + 1], ch[0].rel) : -1;
  for (int i = best + 1; i < nsnaps; i++) free_snap_later(&snaps[i]);  // (killed once the pass is out: kill_doomed)
  nsnaps = best + 1;
  snap *s = &snaps[best];
  char p[4096];
  // (a pass from far back would typeset pages before the paragraph: slower than the exact page, and not the
  // paragraph's own lines if a float or page break comes between; the next key resumes at the edited line)
  if (dbg && para && hook && !rerun && nch == 1 &&
      !(s->cur && !strcmp(s->cur, ch[0].rel) && s->cur_pos <= ch[0].k && ch[0].k - s->cur_pos < 4096))
    fprintf(dbg, "no pass: snapshot in %s at %ld, edit at %ld, pages %d\n", s->cur ? s->cur : "-", s->cur_pos, ch[0].k,
            s->pages), fflush(dbg);
  if (para && hook && !rerun && nch == 1 && s->cur && !strcmp(s->cur, ch[0].rel) && s->cur_pos <= ch[0].k &&
      ch[0].k - s->cur_pos < 4096) {
    text *t = get_text(ch[0].rel);
    pid_t warm = s->warm;
    if (warm > 0) snprintf(p, sizeof p, "%s/ctl-warm-%d", tdir, warm);
    else snprintf(p, sizeof p, "%s/ctl-para-%d", tdir, s->pid);
    FILE *f = fopen(p, "w");
    fprintf(f, "seq %d\nfile %s\nend %ld\n", seq, ch[0].rel, para_end(t, ch[0].k));
    pass.seq = seq;
    snprintf(pass.rel, sizeof pass.rel, "%s", ch[0].rel);
    pass.end = para_end(t, ch[0].k);
    pass.line = line_of(t, pass.end);
    // the pass ships its lines where the old ones are on their page (same page origin, so the engine rounds their
    // positions as on the exact page, and the overlay needs no offset): the old first baseline, from SyncTeX, and the
    // old lines' left edge. Across, because the pass takes its lines off with \lastbox, which drops each line's
    // shift (a list item's indent, from \parshape): shipped at the text's left edge, a list item's preview stood
    // 25 pt left of the page's lines, and the paragraph jumped sideways at every key (item 8). Lines shifted by
    // different amounts (a hanging indent, a shaped paragraph) get no left edge, and no preview (para_lines).
    char yb[64] = "", xb[64] = "";
    {
      sx_index *x;
      sx_para o;
      out_rec *src;
      old_lines(&x, &o, &src);
      if (src && o.found == 1) {
        double u = x->unit > 0 ? x->unit : 1;
        snprintf(yb, sizeof yb, "%ld", (long)(x->r[o.first].v * u) - 4736286L);
        if (same_left(x, &o)) snprintf(xb, sizeof xb, "%ld", (long)(x->r[o.first].h * u) - 4736286L);
      }
    }
    // LaTeX's own output routine still handles its float penalties (below -10000); a page break ships at natural
    // height through LaTeX's \shipout (its hooks define what the page's \write nodes expand to; no headers)
    // at the pass's own break (\taudotpg defined: the paragraph is over) only its last \prevgraf lines are shipped,
    // taken off with \lastbox, through the primitive \shipout; if anything but lines, glue and penalties is in the
    // way (a footnote's insert, a mark, a whatsit) the page so far ships instead, as at a break inside the paragraph
    fprintf(f, "prefix \\gdef\\taudotg{}\\gdef\\taudotown{0}\\gdef\\taudotn{0}\\gdef\\taudotyb{%s}\\gdef\\taudotxb{%s}"
               "\\toks255=\\expandafter{\\the\\output}\\output={\\taudotout}%%\n", yb, xb);
    fprintf(f, "flush \\taudotflush%%\n");
    int has_text = 0;
    {  // the paragraph's new text from the resume point, so the pass needn't reread the file
      long E = para_end(t, ch[0].k), P = s->cur_pos;
      if (P >= 0 && E >= P && E - P < 32768) {
        has_text = 1;
        fprintf(f, "text %ld %ld\n--\n", P, E - P);
        fwrite(t->data + P, 1, E - P, f);
      }
    }
    fclose(f);
    if (warm > 0 && !has_text) flush_texts();  // (it rereads the file from the clone: write it first)
    if (warm > 0) {  // the warm pass starts now; the snapshot parks a new one when this one exits
      char fifo[4200];
      snprintf(fifo, sizeof fifo, "%s/fifo-%d", tdir, warm);
      int ff = open(fifo, O_WRONLY | O_NONBLOCK);
      if (ff >= 0) { write(ff, "g", 1); close(ff); }  // (TAU_WARM_PIPE)
      else kill(warm, SIGUSR1);
      if (dbg) fprintf(dbg, "%lld signalled warm %d, %lld us after the edit\n", (long long)now_us(), warm, (long long)(now_us() - t_apply)), fflush(dbg);
      s->warm = 0;
    }
  }
  flush_texts();  // (the runner reloads the changed files from the clone)
  snprintf(p, sizeof p, "%s/ctl-%d", tdir, s->pid);
  FILE *f = fopen(p, "w");
  static int go;  // each resume's orders differ (a snapshot woken twice for the same orders forks one runner)
  fprintf(f, "seq %d\ngo %d\n", seq, ++go);
  for (int c = 0; c < nch; c++) fprintf(f, "load %s\n", ch[c].rel);
  if (nch) fprintf(f, "edit %s %ld\n", ch[0].rel, ch[0].k);
  if (nch && dense > 0)  // typing is local: a snapshot at every line near the edit
  {
    text *t = get_text(ch[0].rel);  // from the start of the edited line (paragraphs are often one long line)
    long lo = ch[0].k > dense ? ch[0].k - dense : 0;
    long ls = ch[0].k;
    while (ls > 0 && (size_t)ls <= t->len && t->data[ls - 1] != '\n') ls--;
    if (ls < lo) lo = ls;
    fprintf(f, "dense %s %ld %ld\n", ch[0].rel, lo, ch[0].k + 1);
  }
  fprintf(f, "finish %s\n", finish_every ? "every" : "rule");
  fprintf(f, "snapms %ld\n", snapshot_ms);
  fclose(f);
  kill(s->pid, SIGUSR1);
  if (dbg) {
    fprintf(dbg, "%lld apply seq %d -> snapshot %d (%d of %d) edit %s@%ld snapshot extent %ld; next %ld\n",
            (long long)now_us(), seq, s->pid, best, nsnaps, ch[0].rel, ch[0].k, snap_extent(s, ch[0].rel),
            next_ext);
    fflush(dbg);
  }
  run_open = 1;
  from_page = s->pages;  // (pages shipped before the snapshot the run resumes from: unchanged)
  emit("{\"ev\":\"run\",\"seq\":%d,\"run\":%d,\"applied\":%d,\"why\":\"%s\",\"from_page\":%d,\"snapshot\":%d,"
       "\"snapshots\":%d}",
       seq, run_no, applied_at_run, why, from_page, s->pid, nsnaps);
}

// The engine's processes reload changed files from the clone: write them there (only the exact runner and fresh
// starts read them; a warm pass gets its text in its orders)
static void flush_texts(void) {
  for (int i = 0; i < ntexts; i++)
    if (texts[i].dirty) {
      char p[4096];
      snprintf(p, sizeof p, "%s/%s", work, texts[i].rel);
      write_file(p, texts[i].data, texts[i].len);
      texts[i].dirty = 0;
    }
}
static void set_text(const char *rel, char *data, size_t len, const char *why) {
  text *t = get_text(rel);
  size_t k = 0;
  size_t m = t->len < len ? t->len : len;
  while (k < m && t->data[k] == data[k]) k++;
  if (k == m && t->len == len) { free(data); return; }
  free(t->data);
  t->data = data;
  t->len = t->cap = len;
  t->dirty = 1;
  t->lc_pos = 0, t->lc_line = 1;
  change c = {(char *)rel, (long)k};
  apply(&c, 1, why);
}
// An edit at a known place: in place, no comparison of the whole text (it cost the file's length on every key)
static void edit_text(const char *rel, size_t pos, size_t del, const char *ins, size_t n, const char *why) {
  text *t = get_text(rel);
  if (!del && !n) return;
  size_t len = t->len - del + n;
  if (len + 1 > t->cap) {
    t->cap = len + 1 + len / 4;
    t->data = realloc(t->data, t->cap);
  }
  if ((long)pos < t->lc_pos) {  // (the known line point moves with the text after the edit)
    if ((long)(pos + del) > t->lc_pos) t->lc_pos = 0, t->lc_line = 1;
    else {
      int nl = 0;
      for (size_t i = 0; i < del; i++) nl -= t->data[pos + i] == '\n';
      for (size_t i = 0; i < n; i++) nl += ins[i] == '\n';
      t->lc_pos += (long)n - (long)del, t->lc_line += nl;
    }
  }
  memmove(t->data + pos + n, t->data + pos + del, t->len - pos - del);
  memcpy(t->data + pos, ins, n);
  t->len = len;
  t->dirty = 1;
  change c = {(char *)rel, (long)pos};
  apply(&c, 1, why);
}

// ---------------------------------------------------------------------------------------------------- outputs

static const char *out_ext(void) {
  return strstr(eng_argv[0], "xetex") || strstr(eng_argv[0], "xelatex") ? "xdv" : "pdf";
}
static const char *job_stem(void) {
  static char stem[1024];
  snprintf(stem, sizeof stem, "%s", mainf);
  char *dot = strrchr(stem, '.');
  if (dot) *dot = 0;
  for (int i = 1; eng_argv[i]; i++)
    if (!strncmp(eng_argv[i], "-jobname=", 9)) snprintf(stem, sizeof stem, "%s", eng_argv[i] + 9);
  return stem;
}
static int exists(const char *p) { return access(p, F_OK) == 0; }

static void emit_pdf(const char *tag, int s, pid_t pid, int pages, int final, int64_t t) {
  pdf_out_seq = s, pdf_out_run = run_no;
  char d[4096], pdf[4600], sx[4600], lg[4600];
  snprintf(d, sizeof d, "%s/%s-%d-%d", tdir, tag, s, pid);
  snprintf(pdf, sizeof pdf, "%s/%s.%s", d, job_stem(), out_ext());
  snprintf(lg, sizeof lg, "%s/%s.log", d, job_stem());
  snprintf(sx, sizeof sx, "%s/%s.synctex", d, job_stem());
  if (!exists(sx)) snprintf(sx, sizeof sx, "%s/%s.synctex.gz", d, job_stem());
  int64_t fs = t_fin_start[pid & 0xffff];
  int sx_slot = -1;
  if (exists(sx)) {
    sx_slot = nouts % 8;
    out_rec *o = &outs[nouts++ % 8];
    snprintf(o->path, sizeof o->path, "%s", pdf);
    snprintf(o->sx, sizeof o->sx, "%s", sx);
    o->applied = applied_at_run;
  }
  // XDV: the pages from the first one the client may not have (pages before it came in earlier events) to the end,
  // converted by tau-pdfmx; the event waits for them (pdfmx_answer)
  int conv = pdfmx_in >= 0 && pages > 0 && !strcmp(out_ext(), "xdv") && exists(pdf) && noq < 62;
  char *evs = NULL;
  size_t evn = 0;
  FILE *o = conv ? open_memstream(&evs, &evn) : EVO;
  fprintf(o, "{\"ev\":\"pdf\",\"seq\":%d,\"run\":%d,\"applied\":%d,\"pages\":%d,\"final\":%s,\"from_page\":%d,"
          "\"path\":", s, run_no, applied_at_run, pages, final ? "true" : "false", from_page);
  jstr(o, pdf, strlen(pdf));
  if (exists(sx)) { fputs(",\"synctex\":", o); jstr(o, sx, strlen(sx)); }
  if (exists(lg)) { fputs(",\"log\":", o); jstr(o, lg, strlen(lg)); }
  fprintf(o, ",\"edit_us\":%lld,\"finish_us\":%lld%s", (long long)(t - t_apply),
          (long long)(!final && fs ? t - fs : 0), conv ? "" : "}\n");
  if (!conv) {
    fflush(o);
  } else {
    fclose(o);
    // the pages to convert: from the first that changed (never past what the client has: no gap) to the last
    xdv_info x;
    int np = xdv_hashes(pdf, &x), first = pages, last = -1;
    if (np != pages) {  // (unreadable: all of them from from_page, as before)
      first = from_page < ndlv ? from_page : ndlv, last = pages - 1, ndlv = 0;
      xdv_free(&x);
    } else {
      int same_doc = ndlv && x.base == dlvx.base && fonts_agree(&x, &dlvx);
      if (same_doc) {  // the client's fonts: theirs, and this output's new ones
        for (int i = 0; i < x.nf; i++) {
          int j = 0;
          while (j < dlvx.nf && dlvx.fid[j] != x.fid[i]) j++;
          if (j < dlvx.nf) continue;
          dlvx.fid = realloc(dlvx.fid, (dlvx.nf + 1) * sizeof *dlvx.fid);
          dlvx.fh = realloc(dlvx.fh, (dlvx.nf + 1) * sizeof *dlvx.fh);
          dlvx.fid[dlvx.nf] = x.fid[i], dlvx.fh[dlvx.nf++] = x.fh[i];
        }
      }
      for (int k = 0; k < pages; k++)
        if (k >= ndlv || !same_doc || x.hs[k] != dlv[k]) { if (k < first) first = k; last = k; }
      if (first > ndlv) first = ndlv;
      if (np > capdlv) dlv = realloc(dlv, (capdlv = np + 64) * sizeof *dlv);
      memcpy(dlv, x.hs, np * sizeof *dlv);
      if (final || np > ndlv) ndlv = np;  // (an early output ends sooner: the client keeps the pages after it)
      if (!same_doc) {  // the pages after it were made under other definitions: they're converted again next time
        if (ndlv > np) ndlv = np;
        xdv_free(&dlvx);
        dlvx = x;
      } else {
        xdv_free(&x);
      }
    }
    if (first < 0) first = 0;
    if (oq_tail) {  // events already held go out before this one
      fclose(oq_tail);
      oq[noq++] = (oq_ent){oq_tail_s, oq_tail_n, 0, 0, 0, 0, ""};
      oq_tail = NULL, oq_tail_s = NULL, oq_tail_n = 0;
    }
    oq_ent *e = &oq[noq++];
    *e = (oq_ent){evs, evn, 1, first, last, now_us(), ""};
    snprintf(e->pdf, sizeof e->pdf, "%s/%s-%d-%d.pdf", d, job_stem(), first, last);
    if (last < first) {  // no page changed: nothing to convert
      pdfmx_answer_ent(e, 0);
    } else {
      char req[16384];
      int rn = snprintf(req, sizeof req, "%s\t-q\t-z\t1\t-s\t%d-%d\t-o\t%s\t%s\n", work, first + 1, last + 1, e->pdf, pdf);
      if (rn >= (int)sizeof req || write(pdfmx_in, req, rn) != rn) pdfmx_stop();
    }
  }
  static int warmed;  // XeTeX: the reader loads the document's fonts now, not at the first pass (~50 ms)
  if (!warmed && hook && para && reader_in >= 0 && njobs < 16 && !strcmp(out_ext(), "xdv") && exists(pdf)) {
    char req[4700];
    int rn = snprintf(req, sizeof req, "warm\t%s\n", pdf);
    if (rn < (int)sizeof req && write(reader_in, req, rn) == rn) jobs[njobs++] = (reader_job){NULL, -1, now_us(), 0};
    warmed = 1;
  }
  // pdfTeX, LuaTeX: the reader reads this output now (the next pass and display page are drawn against the newest
  // output), when idle
  if (hook && (para || display_pages) && reader_in >= 0 && !njobs && strcmp(out_ext(), "xdv") &&
      (sx_slot >= 0 || display_pages) && pages > 0 && exists(pdf)) {
    char req[4700];
    int rn = snprintf(req, sizeof req, "warmpdf\t%s\n", pdf);
    if (rn < (int)sizeof req && write(reader_in, req, rn) == rn) jobs[njobs++] = (reader_job){NULL, -1, now_us(), 1};
  }
  if (!strcmp(out_ext(), "pdf") && exists(pdf) && pages > 0) {
    snprintf(last_exact, sizeof last_exact, "%s", pdf);
    last_exact_pages = pages;
  }
  if (sx_slot >= 0 && hook && para) {  // its SyncTeX, read now rather than when the next pass is waiting on it
    int64_t t0 = now_us();
    sx_load(&sxs[sx_slot], outs[sx_slot].sx);
    if (dbg) fprintf(dbg, "synctex %s: %d records, %lld us\n", outs[sx_slot].sx, sxs[sx_slot].n, (long long)(now_us() - t0));
  }
}

// ---------------------------------------------------------------------------------------------------- latexmk's rule

static char *slurp_file(const char *p, size_t *n) {
  FILE *f = fopen(p, "rb");
  if (!f) { *n = 0; return NULL; }
  fseek(f, 0, SEEK_END);
  *n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *b = malloc(*n + 1);
  *n = fread(b, 1, *n, f);
  b[*n] = 0;
  fclose(f);
  return b;
}

static int is_output_name(const char *rel) {  // the run's document and logs: not inputs of a later run
  const char *e = strrchr(rel, '.');
  if (!e) return 0;
  return !strcmp(e, ".pdf") || !strcmp(e, ".xdv") || !strcmp(e, ".dvi") || !strcmp(e, ".log") ||
         !strcmp(e, ".synctex") || !strcmp(e, ".gz") || !strcmp(e, ".fls");
}

// The bib lines of the main .aux and of every .aux it \@inputs (\include'd chapters), as BibTeX reads them.
static char *bib_lines(void) {
  size_t cap = 4096, n = 0;
  char *outb = malloc(cap);
  outb[0] = 0;
  char todo[64][1024];
  int nt = 0, done = 0;
  snprintf(todo[nt++], 1024, "%s.aux", job_stem());
  while (done < nt) {
    char p[4200];
    snprintf(p, sizeof p, "%s/%s", work, todo[done++]);
    size_t len;
    char *a = slurp_file(p, &len);
    if (!a) continue;
    for (char *l = a; l && *l;) {
      char *e = strchr(l, '\n');
      size_t ll = e ? (size_t)(e - l) : strlen(l);
      if (!strncmp(l, "\\citation{", 10) || !strncmp(l, "\\bibdata{", 9) || !strncmp(l, "\\bibstyle{", 10)) {
        while (n + ll + 2 > cap) outb = realloc(outb, cap *= 2);
        memcpy(outb + n, l, ll), n += ll, outb[n++] = '\n', outb[n] = 0;
      } else if (!strncmp(l, "\\@input{", 8) && nt < 64) {
        char *c = strchr(l + 8, '}');
        if (c) snprintf(todo[nt++], 1024, "%.*s", (int)(c - l - 8), l + 8);
      }
      l = e ? e + 1 : NULL;
    }
    free(a);
  }
  return outb;
}

// latexmk's -bibtex-cond: BibTeX only when every database \bibdata names is there (a project may ship only its .bbl,
// as arXiv sources do: BibTeX would replace it with an empty one)
static int bib_files_exist(const char *lines) {
  int any = 0;
  for (const char *l = strstr(lines, "\\bibdata{"); l; l = strstr(l + 1, "\\bibdata{")) {
    const char *s = l + 9, *e = strchr(s, '}');
    if (!e) return 0;
    while (s < e) {
      const char *c = memchr(s, ',', e - s);
      if (!c) c = e;
      char name[1024], p[4300], p2[4400];
      snprintf(name, sizeof name, "%.*s", (int)(c - s), s);
      snprintf(p, sizeof p, "%s/%s", work, name);
      snprintf(p2, sizeof p2, "%s.bib", p);
      if (!*name || (!exists(p2) && !(strlen(name) > 4 && !strcmp(name + strlen(name) - 4, ".bib") && exists(p))))
        return 0;
      any = 1;
      s = c + 1;
    }
  }
  return any;
}

static unsigned long bib_hash(void) {  // every .bib in the project (FNV-1a over names and contents)
  unsigned long h = 1469598103934665603UL;
  DIR *dd = opendir(work);
  struct dirent *de;
  while (dd && (de = readdir(dd))) {
    size_t l = strlen(de->d_name);
    if (l < 5 || strcmp(de->d_name + l - 4, ".bib")) continue;
    char p[4200];
    snprintf(p, sizeof p, "%s/%s", work, de->d_name);
    size_t n;
    char *b = slurp_file(p, &n);
    for (size_t i = 0; i < l; i++) h = (h ^ (unsigned char)de->d_name[i]) * 1099511628211UL;
    for (size_t i = 0; b && i < n; i++) h = (h ^ (unsigned char)b[i]) * 1099511628211UL;
    free(b);
  }
  if (dd) closedir(dd);
  return h;
}

static int run_tool(const char *bin, const char *arg) {  // in the clone, without libtau, output to engine.out
  pid_t pid;
  char logp[4200];
  snprintf(logp, sizeof logp, "%s/engine.out", tdir);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&fa, 1, logp, O_WRONLY | O_CREAT | O_APPEND, 0644);
  posix_spawn_file_actions_adddup2(&fa, 1, 2);
  posix_spawn_file_actions_addchdir(&fa, work);
  char *argv[] = {(char *)bin, (char *)arg, NULL};
  int n = 0;
  while (environ[n]) n++;
  char **env = calloc(n + 1, sizeof *env);
  int k = 0;
  for (int i = 0; i < n; i++)
    if (strncmp(environ[i], "DYLD_INSERT_LIBRARIES=", 22)) env[k++] = environ[i];
  int st = -1;
  if (posix_spawn(&pid, bin, &fa, NULL, argv, env) == 0) waitpid(pid, &st, 0);
  posix_spawn_file_actions_destroy(&fa);
  free(env);
  return WIFEXITED(st) ? WEXITSTATUS(st) : 3;
}

static long first_diff(const char *a, size_t an, const char *b, size_t bn) {
  size_t k = 0, m = an < bn ? an : bn;
  while (k < m && a[k] == b[k]) k++;
  return (k == m && an == bn) ? -1 : (long)k;
}

typedef struct { char rel[1024]; long k; } rchange;

// A written file of the run (in DIR) into the clone if it differs: that's what latexmk would see on disk.
static int take_outputs(const char *dirp, const char *prefix, rchange *ch, int max, int n) {
  DIR *dd = opendir(dirp);
  struct dirent *de;
  while (dd && (de = readdir(dd)) && n < max) {
    if (de->d_name[0] == '.') continue;
    char src[4200], rel[2048], dst[4200];
    snprintf(src, sizeof src, "%s/%s", dirp, de->d_name);
    snprintf(rel, sizeof rel, "%s%s", prefix, de->d_name);
    struct stat st;
    if (stat(src, &st)) continue;
    if (S_ISDIR(st.st_mode)) {
      char pre[2100];
      snprintf(pre, sizeof pre, "%s/", rel);
      n = take_outputs(src, pre, ch, max, n);
      continue;
    }
    if (is_output_name(rel)) continue;
    snprintf(dst, sizeof dst, "%s/%s", work, rel);
    size_t an, bn;
    char *a = slurp_file(src, &an), *b = slurp_file(dst, &bn);
    long k = first_diff(b ? b : "", b ? bn : 0, a ? a : "", a ? an : 0);
    if (k >= 0) {
      write_file(dst, a ? a : "", an);
      snprintf(ch[n].rel, sizeof ch[n].rel, "%s", rel);
      ch[n++].k = b ? k : 0;
    }
    free(a), free(b);
  }
  if (dd) closedir(dd);
  return n;
}

static void keep_state(void) {  // --state: the compile settled; keep what the next session's first run needs
  if (!state_dir[0]) return;
  const char *exts[] = {"aux", "bbl", "blg", "toc", "out", NULL};
  for (int i = 0; exts[i]; i++) {
    char a[4200], b[4200];
    snprintf(a, sizeof a, "%s/%s.%s", work, job_stem(), exts[i]);
    snprintf(b, sizeof b, "%s/%s.%s", state_dir, job_stem(), exts[i]);
    size_t n;
    char *d = slurp_file(a, &n);
    if (d) write_file(b, d, n);
    free(d);
  }
  char r[4200];
  snprintf(r, sizeof r, "%s/rule", state_dir);
  FILE *f = fopen(r, "w");
  if (f) { fprintf(f, "%lu\n", bib_hash_last); fclose(f); }
}

static void restore_state(void) {
  if (!state_dir[0]) return;
  mkdir(state_dir, 0755);
  const char *exts[] = {"aux", "bbl", "blg", "toc", "out", NULL};
  for (int i = 0; exts[i]; i++) {
    char a[4200], b[4200];
    snprintf(a, sizeof a, "%s/%s.%s", work, job_stem(), exts[i]);
    snprintf(b, sizeof b, "%s/%s.%s", state_dir, job_stem(), exts[i]);
    if (exists(a)) continue;
    size_t n;
    char *d = slurp_file(b, &n);
    if (d) write_file(a, d, n);
    free(d);
  }
  char r[4200];
  snprintf(r, sizeof r, "%s/rule", state_dir);
  FILE *f = fopen(r, "r");
  unsigned long h = 0;
  if (f) { if (fscanf(f, "%lu", &h) != 1) h = 0; fclose(f); }
  char bbl[4200];
  snprintf(bbl, sizeof bbl, "%s/%s.bbl", work, job_stem());
  // a kept .bbl made from these .bib files: BibTeX already ran on the kept .aux
  if (exists(bbl) && h && h == bib_hash()) { bib_state = bib_lines(); bib_hash_last = h; }
}

// BibTeX or biber, and makeindex, as latexmk would: returns the changes they made (the .bbl, the .ind).
static int run_tools(rchange *ch, int max, int n) {
  char p[4200], bbl[4200];
  const char *stem = job_stem();
  snprintf(bbl, sizeof bbl, "%s/%s.bbl", work, stem);
  size_t on;
  char *old = slurp_file(bbl, &on);
  char tools[64] = "";
  int code = 0, ran_bib = 0;
  snprintf(p, sizeof p, "%s/%s.bcf", work, stem);
  if (biber_bin[0] && exists(p)) {
    char *lines = bib_lines();  // (biber: the .bcf decides; its hash stands in for the bib lines)
    size_t bn;
    char *bcf = slurp_file(p, &bn);
    unsigned long h = bib_hash() ^ (bn * 2654435761UL);
    for (size_t i = 0; bcf && i < bn; i++) h = (h ^ (unsigned char)bcf[i]) * 1099511628211UL;
    free(bcf);
    if (!bib_state || h != bib_hash_last) {
      code = run_tool(biber_bin, stem), ran_bib = 1, strcat(tools, "biber");
      free(bib_state), bib_state = lines, bib_hash_last = h;
    } else free(lines);
  } else if (bibtex_bin[0]) {
    char *lines = bib_lines();
    unsigned long h = bib_hash();
    int has_bibdata = bib_files_exist(lines);
    if (has_bibdata && (!bib_state || strcmp(lines, bib_state) || h != bib_hash_last)) {
      code = run_tool(bibtex_bin, stem), ran_bib = 1, strcat(tools, "bibtex");
      free(bib_state), bib_state = lines, bib_hash_last = h;
    } else free(lines);
  }
  if (makeindex_bin[0]) {
    static unsigned long idx_last;
    char idx[4200];
    snprintf(idx, sizeof idx, "%s/%s.idx", work, stem);
    size_t in;
    char *ib = slurp_file(idx, &in);
    if (ib) {
      unsigned long h = 1469598103934665603UL;
      for (size_t i = 0; i < in; i++) h = (h ^ (unsigned char)ib[i]) * 1099511628211UL;
      if (h != idx_last) {
        char ind[4200], arg[1100];
        snprintf(ind, sizeof ind, "%s/%s.ind", work, stem);
        size_t dn;
        char *before = slurp_file(ind, &dn);
        snprintf(arg, sizeof arg, "%s.idx", stem);
        run_tool(makeindex_bin, arg);
        idx_last = h;
        if (*tools) strcat(tools, ",");
        strcat(tools, "makeindex");
        size_t an;
        char *after = slurp_file(ind, &an);
        long k = first_diff(before ? before : "", before ? dn : 0, after ? after : "", after ? an : 0);
        if (k >= 0 && n < max) { snprintf(ch[n].rel, sizeof ch[n].rel, "%s.ind", stem); ch[n++].k = before ? k : 0; }
        free(before), free(after);
      }
      free(ib);
    }
  }
  int bbl_changed = 0;
  if (ran_bib) {
    size_t nn;
    char *now = slurp_file(bbl, &nn);
    long k = first_diff(old ? old : "", old ? on : 0, now ? now : "", now ? nn : 0);
    if (k >= 0 && n < max) { snprintf(ch[n].rel, sizeof ch[n].rel, "%s.bbl", stem); ch[n++].k = old ? k : 0; bbl_changed = 1; }
    free(now);
    snprintf(blg_this, sizeof blg_this, "%s/%s.blg", work, stem);
  }
  if (*tools) {
    fprintf(EVO, "{\"ev\":\"bibtex\",\"seq\":%d,\"code\":%d,\"tool\":\"%s\"", seq, code, tools);
    if (ran_bib) { fputs(",\"blg\":", EVO); jstr(EVO, blg_this, strlen(blg_this)); }
    fprintf(EVO, ",\"bbl_changed\":%s}\n", bbl_changed ? "true" : "false");
    fflush(EVO);
  }
  free(old);
  return n;
}

// A run ended: its written files into the clone; BibTeX & co.; a rerun from the snapshot before the first changed
// byte of any changed file the run had read; else the compile has settled (done).
// A run that made nothing: was it the format? (TeX says so on its terminal before it reads anything)
static void check_format(int code, int pages) {
  if (code == 0 || pages > 0) return;
  char p[4200];
  snprintf(p, sizeof p, "%s/engine.out", tdir);
  size_t n;
  char *b = slurp_file(p, &n);
  if (!b) return;
  size_t from = n > 4096 ? n - 4096 : 0;
  char *m = strstr(b + from, "can't find the format file");
  if (!m) m = strstr(b + from, "Fatal format file error");
  if (m) {
    char msg[300];
    snprintf(msg, sizeof msg, "%.*s", (int)strcspn(m, "\n"), m);
    fprintf(EVO, "{\"ev\":\"error\",\"what\":\"format\",\"message\":");
    jstr(EVO, msg, strlen(msg));
    fputs("}\n", EVO);
    fflush(EVO);
  }
  free(b);
}

static void rule_step(pid_t pid, int pages, int64_t t, int code) {
  check_format(code, pages);
  char d[4096];
  snprintf(d, sizeof d, "%s/run-%d-%d", tdir, seq, pid);
  static rchange ch[256];
  int n = take_outputs(d, "", ch, 256, 0);
  snap ext = {.pid = pid};
  read_extents(&ext);  // what this run read (its exit wrote s-<pid>)
  n = run_tools(ch, 256, n);
  int need = 0;
  const char *why = "aux";
  for (int i = 0; i < n; i++)
    if (snap_extent(&ext, ch[i].rel) > 0) {
      need = 1;
      const char *e = strrchr(ch[i].rel, '.');
      if (e && !strcmp(e, ".bbl")) why = "bibtex";
    }
  free_snap(&ext);
  if (need && run_no < max_runs) {
    static change c[256];
    for (int i = 0; i < n; i++) c[i].rel = ch[i].rel, c[i].k = ch[i].k;
    // only the files it read decide where to resume; the others are just on disk now
    int m = 0;
    for (int i = 0; i < n; i++) c[m++] = c[i];
    apply_run(c, m, why, 1);
    return;
  }
  char pdf[4600], lg[4600];
  snprintf(pdf, sizeof pdf, "%s/%s.%s", d, job_stem(), out_ext());
  snprintf(lg, sizeof lg, "%s/%s.log", d, job_stem());
  fprintf(EVO, "{\"ev\":\"done\",\"seq\":%d,\"runs\":%d,\"pages\":%d,\"code\":%d", seq, run_no, pages, code);
  if (exists(pdf)) { fputs(",\"path\":", EVO); jstr(EVO, pdf, strlen(pdf)); }
  if (exists(lg)) { fputs(",\"log\":", EVO); jstr(EVO, lg, strlen(lg)); }
  if (blg_this[0]) { fputs(",\"blg\":", EVO); jstr(EVO, blg_this, strlen(blg_this)); }
  fprintf(EVO, ",\"edit_us\":%lld,\"fresh_runs\":%d}\n", (long long)(t - t_apply), fresh_runs);
  fflush(EVO);
  keep_state();
}

static char *deferred[1024];
static int ndeferred;
static void defer(const char *line) {
  if (ndeferred < 1024) deferred[ndeferred++] = strdup(line);
}
static void on_msg(char *line);
static void replay(void) {  // messages that were waiting for their runner: retry while the runner moves on
  for (;;) {
    pid_t before = runner;
    int n = ndeferred;
    char *l[1024];
    memcpy(l, deferred, n * sizeof *l);
    ndeferred = 0;
    for (int i = 0; i < n; i++) { on_msg(l[i]); free(l[i]); }
    if (runner == before) return;
  }
}
static void drop_deferred(void) {
  for (int i = 0; i < ndeferred; i++) {
    int a, b;
    if (sscanf(deferred[i], "W %d %d", &a, &b) == 2) kill(b, SIGKILL);
    free(deferred[i]);
  }
  ndeferred = 0;
}

// ---------------------------------------------------------------------------------------------------- para events
// docs/live-protocol.md `para`, as the patched pdfTeX gives it: state, page, the lines as a TDL (path) and as a
// one-page PDF (overlay, pdfTeX/LuaTeX), erase rects. The old lines' place comes from the newest output's SyncTeX.

// The paragraph's old lines: the newest output whose SyncTeX has them (the paragraph's \par line, pass.line, in that
// output's text)
static void old_lines(sx_index **xp, sx_para *op, out_rec **srcp) {
  sx_index *x = NULL;
  sx_para o = {0};
  out_rec *src = NULL;
  for (int k = 0; k < 8 && k < nouts && !src; k++) {    int slot = (nouts - 1 - k) % 8;
    out_rec *r = &outs[slot];
    int L = pass.line, ok = 1;
    for (int i = 0; i < nerecs && i < 1024; i++) {
      edit_rec *e = &erecs[(nerecs - 1 - i) % 1024];
      if (e->applied <= r->applied) break;
      if (strcmp(e->rel, pass.rel) || e->pos >= pass.end) continue;
      if (e->nl == INT_MIN) { ok = 0; break; }
      L -= e->nl;
    }
    if (!ok || !sx_load(&sxs[slot], r->sx)) continue;
    o = sx_find(&sxs[slot], pass.rel, L);
    if (dbg) fprintf(dbg, "para anchor: %s line %d (now %d) in %s: %d records, found %d\n", pass.rel, L, pass.line, r->sx,
                     sxs[slot].n, o.found), fflush(dbg);
    if (o.found) { x = &sxs[slot], src = r; }
  }
  *xp = x, *op = o, *srcp = src;
}

static int pass_out_seq = -1;  // the last edit whose pass has finished (its Q or its end)
static void para_none(int s, const char *why, int lines, int pieces, const char *bin) {
  pass_out_seq = s;
  fprintf(stdout, "{\"ev\":\"para\",\"go\":%d,\"seq\":%d,\"applied\":%d,\"file\":", s, s, applied_at_run);
  jstr(stdout, pass.rel, strlen(pass.rel));
  fprintf(stdout, ",\"state\":\"none\",\"why\":\"%s\",\"lines\":%d,\"pieces\":%d", why, lines, pieces);
  if (bin && *bin) { fputs(",\"bin\":", stdout); jstr(stdout, bin, strlen(bin)); }
  fprintf(stdout, ",\"us\":%lld}\n", (long long)(now_us() - t_apply));
  fflush(stdout);
}

static const double SP_BP = 72.0 / 72.27 / 65536.0;

static void para_lines(const char *line, int s, int lines, int pieces, const char *bin, int64_t t_q) {
  pass_out_seq = s;
  int own = 1, geo = 0;
  long gb = 0, gs = 0, gh = 0;
  long long tstart = 0;
  const char *p = strstr(line, " own ");
  if (p) own = atoi(p + 5);
  p = strstr(line, " geo ");
  if (p) geo = sscanf(p, " geo %d %ld %ld %ld", &geo, &gb, &gs, &gh) == 4 && geo;
  {
    long long a_, b_;
    char path_[2048];
    int x_, y_, z_, w_;
    if (sscanf(line, "Q %d %d %d %d %lld %2047s %lld", &x_, &y_, &z_, &w_, &a_, path_, &b_) == 7) tstart = b_;
  }
  if (dbg) fprintf(dbg, "para timing: Q read %lld us after the stop, %lld after the edit\n", (long long)(now_us() - t_q),
                   (long long)(now_us() - t_apply));
  if (!own) return para_none(s, "insert", lines, pieces, bin);  // in a box: a float, a caption, a minipage
  if (pieces > 1) return para_none(s, "split", lines, pieces, bin);  // the new lines cross a page or column
  if (!geo || lines <= 0) return para_none(s, lines <= 0 ? "end" : "insert", lines, pieces, bin);  // (insert, mark)
  sx_index *x = NULL;
  sx_para o = {0};
  out_rec *src = NULL;
  old_lines(&x, &o, &src);
  if (!src) return para_none(s, "noanchor", lines, pieces, bin);
  if (o.found == -1) return para_none(s, "split", lines, pieces, bin);
  if (o.found == -2) return para_none(s, "segment", lines, pieces, bin);
  // lines indented by different amounts: the pass shipped them all at the text's left edge (see \taudotxb)
  if (!same_left(x, &o)) return para_none(s, "shape", lines, pieces, bin);
  const sx_rec *r1 = &x->r[o.first], *rn = r1;
  for (int i = o.first + 1, k = 1; i < x->n && k < o.n; i++)
    if (x->r[i].parent == r1->parent) rn = &x->r[i], k++;
  double u = x->unit > 0 ? x->unit : 1;
  if (dbg) fprintf(dbg, "para geo: r1 h %d v %d W %d H %d D %d page %d n %d; pass b %ld s %ld h %ld lines %d\n", r1->h, r1->v,
                   r1->W, r1->H, r1->D, r1->page, o.n, gb, gs, gh, lines), fflush(dbg);
  long top_old = r1->v - r1->H, bot_old = rn->v + rn->D;
  long base_new = 4736286 + gb;  // (1in: the shipped page's origin)
  long oy = r1->v - base_new;    // the pass's page moved down by this: its first baseline on the old one
  long top_new = r1->v - gh, bot_new = top_new + gs;
  double pad = 1.0 / SP_BP;  // half the gap to the next line (1 pt for a one-line paragraph)
  if (o.n > 1) {
    const sx_rec *r2 = NULL;
    for (int i = o.first + 1; i < x->n && !r2; i++)
      if (x->r[i].parent == r1->parent) r2 = &x->r[i];
    double gap = (r2->v - r2->H) - (r1->v + r1->D);
    pad = gap > 0 ? gap / 2 : 0;
  }
  const char *state = "exact", *why = NULL;
  if (o.n != lines) state = "provisional", why = "lines";
  else if (labs(gh - r1->H) > 64 || labs(gs - (bot_old - top_old)) > 64) state = "provisional", why = "heights";
  double X0 = r1->h * u * SP_BP - 3, X1 = (r1->h + r1->W) * u * SP_BP + 3;  // (3: protruded punctuation)
  // the request to the reader; the event goes out with its answer
  if (reader < 0) reader_start();
  if (reader < 0 || njobs == 16) return para_none(s, "reader", lines, pieces, bin);
  int k = npreviews++ % 5;  // (files are reused after four more previews)
  char tdl[4300], ovl[4300], req[16384];
  snprintf(tdl, sizeof tdl, "%s/para-%d.tdl", tdir, k);
  snprintf(ovl, sizeof ovl, "%s/para-%d.pdf", tdir, k);
  int is_pdf = strcmp(out_ext(), "xdv") != 0;
  int page = r1->page;
  if (is_pdf)
    snprintf(req, sizeof req, "pdf\t%s\t%d\t%s\t%s\t%s\t%.4f\n", src->path, page, bin, ovl, tdl, -oy * u * SP_BP);
  else
    snprintf(req, sizeof req, "xdv\t%s\t%s\t%s\t%.4f\n", src->path, bin, tdl, oy * u * SP_BP);
  if (write(reader_in, req, strlen(req)) != (ssize_t)strlen(req)) {
    reader_stop();
    return para_none(s, "reader", lines, pieces, bin);
  }
  char *head = NULL;
  size_t hn = 0;
  FILE *h = open_memstream(&head, &hn);
  fprintf(h, "{\"ev\":\"para\",\"go\":%d,\"seq\":%d,\"applied\":%d,\"file\":", s, s, applied_at_run);
  jstr(h, pass.rel, strlen(pass.rel));
  fprintf(h, ",\"state\":\"%s\"", state);
  if (why) fprintf(h, ",\"why\":\"%s\"", why);
  fputs(",\"pdf\":", h);
  jstr(h, src->path, strlen(src->path));
  fprintf(h, ",\"page\":%d,\"path\":", page);
  jstr(h, tdl, strlen(tdl));
  if (is_pdf) {
    fputs(",\"overlay\":", h);
    jstr(h, ovl, strlen(ovl));
    fputs(",\"origin\":[0,0]", h);
  }
  fprintf(h, ",\"erase\":[[%.3f,%.3f,%.3f,%.3f],[%.3f,%.3f,%.3f,%.3f]]", X0, top_old * u * SP_BP - pad * SP_BP, X1,
          bot_old * u * SP_BP + pad * SP_BP, X0, top_new * u * SP_BP - pad * SP_BP, X1, bot_new * u * SP_BP + pad * SP_BP);
  fprintf(h, ",\"lines\":%d,\"old_lines\":%d,\"pieces\":%d,\"bin\":", lines, o.n, pieces);
  jstr(h, bin, strlen(bin));
  fprintf(h, ",\"engine_us\":%lld", tstart ? (long long)(t_q - tstart) : 0LL);
  fclose(h);
  jobs[njobs++] = (reader_job){head, s, now_us(), is_pdf};
  if (dbg) fprintf(dbg, "para timing: request sent %lld us after the edit, %lld after the stop\n",
                   (long long)(now_us() - t_apply), (long long)(now_us() - t_q)), fflush(dbg);
}

// A display page: page C (1-based) of this run, its data at PP, over the last finished PDF (tau-tdl `page`)
static void display_ask(int c, const char *pp)
{
  if (reader_in < 0 || njobs >= 16) { display_seq = seq; return; }
  char outp[4300], req[16384];
  snprintf(outp, sizeof outp, "%s/display-%d.pdf", tdir, seq % 4);
  int rn = snprintf(req, sizeof req, "page\t%s\t%d\t%s\t%s\n", last_exact, c - 1, pp, outp);
  if (rn >= (int)sizeof req || write(reader_in, req, rn) != rn) { display_seq = seq; return; }
  char *head = NULL;
  size_t hn = 0;
  FILE *h = open_memstream(&head, &hn);
  fprintf(h, "{\"ev\":\"pdf\",\"seq\":%d,\"run\":%d,\"applied\":%d,\"pages\":%d,\"final\":false,"
          "\"from_page\":%d,\"display\":true,\"path\":", seq, run_no, applied_at_run, c, from_page);  // (pages: through this one)
  jstr(h, outp, strlen(outp));
  fclose(h);
  jobs[njobs++] = (reader_job){head, seq, now_us(), 1, 1};
  disp_wait = seq;
}

// The next queued page to the reader: one at a time, and not while the edit's paragraph pass is running (the pass and
// its reader request come first; a `page` request queued in the reader ahead of the pass's would delay the preview)
static void display_pump(void)
{
  if (dq_seq != seq || dq_at >= dq_n || display_seq == seq || disp_wait == seq) return;
  if (pass.seq == seq && pass_out_seq != seq && now_us() - t_apply < 50000) return;  // (a pass that never ends: 50 ms)
  int k = dq_at++;
  display_ask(dq_c[k], dq_path[k]);
}

// An answer from the reader: the oldest request's event goes out
static void reader_answer(const char *l) {
  if (!njobs) return;
  reader_job j = jobs[0];
  memmove(jobs, jobs + 1, --njobs * sizeof *jobs);
  if (dbg) fprintf(dbg, "reader answer: job seq %d (now %d) %s, %lld us after sending: %.120s\n", j.seq, seq,
                   j.page ? "page" : j.head ? "para" : "warm", (long long)(now_us() - j.t_sent), l), fflush(dbg);
  if (j.page) {  // a display page: out as an early output, unless this run's own output came first
    if (j.seq == disp_wait) disp_wait = -1;
    int fresh = j.seq == seq && !(pdf_out_seq == seq && pdf_out_run == run_no);
    if (strstr(l, "\"ok\":true") && fresh) {
      fprintf(EVO, "%s,\"edit_us\":%lld}\n", j.head, (long long)(now_us() - t_apply));
      fflush(EVO);
      display_seq = seq;
    } else if (fresh && strstr(l, "\"error\":\"same\"")) {  // that page didn't change: the next one shipped
      display_pump();
    } else if (j.seq == seq) {
      display_seq = seq;
    }
    free(j.head);
    return;
  }
  if (!strstr(l, "\"ok\":true")) {
    if (dbg) fprintf(dbg, "reader: %s\n", l), fflush(dbg);
    free(j.head);
    if (j.seq == seq) para_none(j.seq, "reader", 0, 0, NULL);
    return;
  }
  if (j.seq == seq) {  // (an older edit's preview, once a newer edit came, isn't sent)
    const char *u = strstr(l, "\"us\":");
    fprintf(stdout, "%s,\"draw_us\":%lld,\"us\":%lld}\n", j.head, u ? atoll(u + 5) : 0LL,
            (long long)(now_us() - t_apply));
    fflush(stdout);
  }
  free(j.head);
}

static void on_msg(char *line) {
  if (dbg) fprintf(dbg, "%lld msg %s\n", (long long)now_us(), line), fflush(dbg);
  char kind;
  int a, b, c;
  long long t;
  char tag[64];
  if (sscanf(line, "H %d %lld", &a, &t) == 2) return;
  if (line[0] == 'B') return;
  if (!strncmp(line, "g offline ", 10)) {  // a TeX Live file couldn't be fetched: no network (once per file)
    static char *said[256];
    static int nsaid;
    for (int i = 0; i < nsaid; i++)
      if (!strcmp(said[i], line + 10)) return;
    if (nsaid < 256) said[nsaid++] = strdup(line + 10);
    char m[2300];
    snprintf(m, sizeof m, "can't fetch %s: no network", line + 10);
    fprintf(EVO, "{\"ev\":\"error\",\"what\":\"offline\",\"message\":");
    jstr(EVO, m, strlen(m));
    fputs(",\"file\":", EVO);
    jstr(EVO, line + 10, strlen(line + 10));
    fputs("}\n", EVO);
    fflush(EVO);
    return;
  }
  if (line[0] == 'G' && line[1] == ' ') {
    nfetch++;
    fprintf(EVO, "{\"ev\":\"fetch\",\"file\":");
    jstr(EVO, line + 2, strlen(line + 2));
    fprintf(EVO, ",\"files\":%d,\"bytes\":0,\"waiting\":true}\n", nfetch);
    fflush(EVO);
    return;
  }
  if (sscanf(line, "S %d %d %d %lld", &a, &b, &c, &t) == 4) {
    if (c != seq) { kill(a, SIGKILL); kill(b, SIGKILL); return; }  // a killed lineage's late word
    if (a != runner) { defer(line); return; }  // its parent's S hasn't come yet (one pipe, many writers)
    if (nsnaps == capsnaps) snaps = realloc(snaps, (capsnaps = capsnaps ? capsnaps * 2 : 64) * sizeof *snaps);
    snap *s = &snaps[nsnaps++];
    s->pid = a, s->seq = c, s->t = t;
    read_extents(s);
    runner = b;
    if (nsnaps > max_snaps) {  // thin: drop every other one between the first and the last
      int w = 1;
      for (int i = 1; i < nsnaps - 1; i++) {
        if (i % 2) { kill(snaps[i].pid, SIGKILL); free_snap(&snaps[i]); }
        else snaps[w++] = snaps[i];
      }
      snaps[w++] = snaps[nsnaps - 1];
      nsnaps = w;
    }
    return;
  }
  if (sscanf(line, "W %d %d", &a, &b) == 2) {
    for (int i = 0; i < nsnaps; i++)
      if (snaps[i].pid == a) {
        if (snaps[i].warm > 0 && snaps[i].warm != b) kill(snaps[i].warm, SIGKILL);
        snaps[i].warm = b;
        return;
      }
    defer(line);  // its snapshot's S may still be on its way (or it is gone: drop_deferred kills it)
    return;
  }
  if (sscanf(line, "R %d %d %d %lld", &a, &b, &c, &t) == 4) {
    if (c != seq) { kill(b, SIGKILL); return; }
    runner = b;
    return;
  }
  if (sscanf(line, "p %d %d %d %lld", &a, &b, &c, &t) == 4) {
    if (a == runner) pages_now = c;
    return;
  }
  {
    char pp[2048];
    if (sscanf(line, "P %d %d %d %2047s", &a, &b, &c, pp) == 4) {  // a page's data: maybe a display page
      if (dbg && b == seq && display_seq != seq)
        fprintf(dbg, "display? runner %d (P from %d) page %d from_page %d exact %d pages, pdf out %d/%d (run %d)\n",
                runner, a, c, from_page, last_exact_pages, pdf_out_seq, pdf_out_run, run_no), fflush(dbg);
      if (display_pages && b == seq && a == runner && display_seq != seq && c - 1 >= from_page && last_exact[0] &&
          !(pdf_out_seq == seq && pdf_out_run == run_no) && !strcmp(out_ext(), "pdf")) {
        if (c - 1 >= from_page + DISPLAY_TRIES || c > last_exact_pages) display_seq = seq;  // (too far: the finish)
        else {
          if (dq_seq != seq) dq_seq = seq, dq_n = dq_at = 0;
          if (dq_n < 64) dq_c[dq_n] = c, snprintf(dq_path[dq_n], sizeof dq_path[0], "%s", pp), dq_n++;
          display_pump();
        }
      }
      return;
    }
  }
  if (sscanf(line, "F %d %d %d %lld", &a, &b, &c, &t) == 4) {
    if (b == seq && nfins < 256) fins[nfins++] = a;
    t_fin_start[a & 0xffff] = t;
    return;
  }
  int code = 0;
  if (sscanf(line, "E %d %d %d %lld %63s %d", &a, &b, &c, &t, tag, &code) >= 5) {
    if (b != seq) return;
    if (!strcmp(tag, "run") && a != runner) { defer(line); return; }
    static int final_seq = -1, final_run = -1;  // the last run whose own (final) output went out
    if (!strcmp(tag, "run")) {
      run_open = 0;
      emit_pdf("run", b, a, c, 1, t);
      final_seq = b, final_run = run_no;
      rule_step(a, c, t, code);
    } else if (!strcmp(tag, "fin")) {
      // a finisher done after its run's own output (forked at the last pages): its pages are no newer, and an early
      // output after the final one would make the client wait for another final one (the app's SyncTeX waits for a
      // quiet `done`)
      if (b == final_seq && run_no == final_run) return;
      emit_pdf("fin", b, a, c, 0, t);
    } else if (!strcmp(tag, "para")) {
      // the pass ended without its stop signal (an error, the input ran out): no lines to show
      para_none(b, "end", 0, 0, NULL);
    }
    return;
  }
  char qpath[2048];
  int qlines, qships;
  if (sscanf(line, "Q %d %d %d %d %lld %2047s", &a, &b, &qlines, &qships, &t, qpath) == 6) {
    if (b == seq) para_lines(line, b, qlines, qships, qpath, t);
    return;
  }
  if (sscanf(line, "X %d %d %d", &a, &b, &c) == 3) {
    if (b == runner) {  // the run crashed: say so, and settle (the next edit resumes from a snapshot)
      run_open = 0;
      emit("{\"ev\":\"error\",\"what\":\"engine\",\"message\":\"engine process %d died (status %d)\"}", b, c);
      emit("{\"ev\":\"done\",\"seq\":%d,\"runs\":1,\"pages\":%d,\"code\":3,\"edit_us\":0}", seq, pages_now);
    }
    return;
  }
  (void)kind;
}

static void stats(void) {
  uint64_t foot = 0, maxf = 0;
  for (int i = 0; i < nsnaps; i++) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(snaps[i].pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0) {
      foot += ri.ri_phys_footprint;
      if (ri.ri_phys_footprint > maxf) maxf = ri.ri_phys_footprint;
    }
  }
  emit("{\"ev\":\"stats\",\"snapshots\":%d,\"footprint\":%llu,\"max_footprint\":%llu,\"fresh_runs\":%d}", nsnaps,
       (unsigned long long)foot, (unsigned long long)maxf, fresh_runs);
}

static void on_cmd(char *line) {
  jval v[8];
  int n = jparse(line, v, 8);
  if (n < 1 || !v[0].is_str) {
    emit("{\"ev\":\"error\",\"what\":\"protocol\",\"message\":\"bad command\"}");
    return;
  }
  const char *c = v[0].s;
  if (!strcmp(c, "change") && n == 5 && v[1].is_str && !v[2].is_str && !v[3].is_str && v[4].is_str) {
    applied++;
    text *t = get_text(v[1].s);
    size_t pos = v[2].i, del = v[3].i;
    if (pos > t->len) pos = t->len;
    if (pos + del > t->len) del = t->len - pos;
    size_t len = t->len - del + v[4].n;
    {
      int nl = 0;
      for (size_t i = 0; i < del; i++) nl -= t->data[pos + i] == '\n';
      for (size_t i = 0; i < v[4].n; i++) nl += v[4].s[i] == '\n';
      note_edit(v[1].s, (long)pos, nl);
    }
    (void)len;
    edit_text(v[1].s, pos, del, v[4].s, v[4].n, "edit");
  } else if (!strcmp(c, "open") && n == 3 && v[1].is_str && v[2].is_str) {
    applied++;
    note_edit(v[1].s, 0, INT_MIN);  // (lines unknown: older outputs can't place this file's paragraphs)
    char *d = malloc(v[2].n + 1);
    memcpy(d, v[2].s, v[2].n);
    set_text(v[1].s, d, v[2].n, "open");
  } else if (!strcmp(c, "stats")) {
    stats();
  } else if (!strcmp(c, "goal") && n == 2 && !v[1].is_str) {  // the last page in view: finish there at once
    char p[4200], b[32];
    snprintf(p, sizeof p, "%s/goal", tdir);
    int l = snprintf(b, sizeof b, "%lld\n", v[1].i);
    write_file(p, b, l);
  } else if (!strcmp(c, "finish")) {  // a PDF of the pages shipped so far, now (once past the edit)
    if (runner > 0 && run_open) kill(runner, SIGUSR2);
  } else if (!strcmp(c, "rescan")) {  // files the engine doesn't get as text changed on disk: latexmk's rule
    char src[4200], dst[4200];
    DIR *dd = opendir(dir);  // .bib, .bst, images, .sty: copy what changed in DIR into the clone
    struct dirent *de;
    static change chg[256];
    static char rels[256][1024];
    int m = 0;
    while (dd && (de = readdir(dd)) && m < 256) {
      if (de->d_name[0] == '.') continue;
      int held = 0;
      for (int i = 0; i < ntexts; i++) if (!strcmp(texts[i].rel, de->d_name)) held = 1;
      if (held) continue;
      snprintf(src, sizeof src, "%s/%s", dir, de->d_name);
      snprintf(dst, sizeof dst, "%s/%s", work, de->d_name);
      struct stat st;
      if (stat(src, &st) || !S_ISREG(st.st_mode)) continue;
      size_t an, bn;
      char *a = slurp_file(src, &an), *b = slurp_file(dst, &bn);
      long k = first_diff(b ? b : "", b ? bn : 0, a ? a : "", a ? an : 0);
      if (k >= 0) {
        write_file(dst, a, an);
        snprintf(rels[m], 1024, "%s", de->d_name);
        chg[m].rel = rels[m], chg[m].k = b ? k : 0, m++;
      }
      free(a), free(b);
    }
    if (dd) closedir(dd);
    static rchange tc[256];
    int t = run_tools(tc, 256, 0);  // a changed .bib: BibTeX now, and a rerun only if the .bbl changed
    for (int i = 0; i < t && m < 256; i++) { snprintf(rels[m], 1024, "%s", tc[i].rel); chg[m].rel = rels[m], chg[m].k = tc[i].k, m++; }
    if (m) apply(chg, m, "rescan");
  } else {
    if (dbg) {
      fprintf(dbg, "unknown command: %d values, first %.40s", n, c);
      for (int i = 1; i < n; i++) fprintf(dbg, " [%d str %d len %zu]", i, v[i].is_str, v[i].n);
      fprintf(dbg, " line %zu bytes: %.80s\n", strlen(line), line);
      fflush(dbg);
    }
    emit("{\"ev\":\"error\",\"what\":\"protocol\",\"message\":\"unknown command\"}");
  }
  for (int i = 0; i < n; i++) free(v[i].s);
}

// tau-live --park SOCKET --engine PATH [options]: an engine kept just past its format load, listening on SOCKET (see
// libtau's park_engine) until stdin closes; a new one every TAU_PARK_RENEW seconds (300), so that TeX's \time and
// \today, set when an engine starts, stay current. Events: {"ev":"parked","pid","socket","us"} each time one is ready.
static pid_t spawn_parked(void) {
  int n = 0;
  while (environ[n]) n++;
  char **env = calloc(n + 16, sizeof *env);
  int k = 0;
  for (int i = 0; i < n; i++)
    if (strncmp(environ[i], "TAU_", 4) && strncmp(environ[i], "DYLD_INSERT_LIBRARIES=", 22)) env[k++] = environ[i];
  static char e[8][4300];
  snprintf(e[0], sizeof e[0], "TAU_PROJECT=%s", work);
  snprintf(e[1], sizeof e[1], "TAU_OUT=%s", tdir);
  snprintf(e[2], sizeof e[2], "TAU_FD=%d", msg_w);
  snprintf(e[3], sizeof e[3], "TAU_LIFE=%d", life_r);
  snprintf(e[4], sizeof e[4], "DYLD_INSERT_LIBRARIES=%s", lib);
  snprintf(e[5], sizeof e[5], "TAU_PARK=%s", park_sock);
  snprintf(e[6], sizeof e[6], "TAU_PARK_SIG=%s", park_sig);
  for (int i = 0; i < 7; i++) env[k++] = e[i];
  for (int i = 0; i < n; i++)  // (variables the engine reads itself, as a session's would have them)
    if (!strncmp(environ[i], "TAU_WARM_", 9) || !strncmp(environ[i], "TAU_PHASES=", 11) ||
        !strncmp(environ[i], "TAU_TLROOT=", 11) || !strncmp(environ[i], "TAU_FETCH=", 10))
      env[k++] = environ[i];
  env[k] = NULL;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  char logp[4300];
  snprintf(logp, sizeof logp, "%s/engine.out", tdir);
  posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&fa, 1, logp, O_WRONLY | O_CREAT | O_APPEND, 0644);
  posix_spawn_file_actions_adddup2(&fa, 1, 2);
  posix_spawn_file_actions_addchdir(&fa, work);
  pid_t z = -1;
  if (posix_spawn(&z, park_argv[0], &fa, NULL, park_argv, env)) z = -1;
  posix_spawn_file_actions_destroy(&fa);
  free(env);
  return z;
}
static int park_loop(void) {
  const char *rs = getenv("TAU_PARK_RENEW");
  int64_t renew = (rs ? atol(rs) : 300) * 1000000LL, started = 0;
  pid_t z = -1;
  char mb[4096];
  size_t ml = 0;
  for (;;) {
    if (z <= 0) {
      static int quick;  // (one that dies at once, again and again: give up)
      if (started && now_us() - started < 2000000 && ++quick > 5) {
        emit("{\"ev\":\"error\",\"what\":\"park\",\"message\":\"the parked engine keeps exiting (see %s/engine.out)\"}", tdir);
        break;
      }
      z = spawn_parked();
      started = now_us();
      if (z <= 0) die("spawn the parked engine");
    }
    struct pollfd pf[2] = {{0, POLLIN, 0}, {msg_r, POLLIN, 0}};
    if (poll(pf, 2, 1000) < 0 && errno != EINTR) die("poll");
    if (pf[0].revents & (POLLIN | POLLHUP)) {
      char b[256];
      if (read(0, b, sizeof b) <= 0) break;
    }
    if (pf[1].revents & POLLIN) {
      ssize_t r = read(msg_r, mb + ml, sizeof mb - ml - 1);
      if (r > 0) {
        ml += r;
        char *s = mb, *nl;
        while ((nl = memchr(s, '\n', mb + ml - s))) {
          *nl = 0;
          int zp;
          long long t;
          if (sscanf(s, "Z %d %lld", &zp, &t) == 2) {
            fprintf(stdout, "{\"ev\":\"parked\",\"pid\":%d,\"socket\":", zp);
            jstr(stdout, park_sock, strlen(park_sock));
            fprintf(stdout, ",\"us\":%lld}\n", (long long)(t - started));
            fflush(stdout);
          }
          s = nl + 1;
        }
        ml = mb + ml - s;
        memmove(mb, s, ml);
      }
    }
    if (waitpid(z, NULL, WNOHANG) == z) z = -1;  // (it died: another)
    else if (now_us() - started > renew) { kill(z, SIGKILL); waitpid(z, NULL, 0); z = -1; }
  }
  if (z > 0) { kill(z, SIGKILL); waitpid(z, NULL, 0); }
  unlink(park_sock);
  if (strstr(outdir, "/tau-park-")) {  // (the scratch directory --park made)
    char cmd[2200];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", outdir);
    if (system(cmd)) {}
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------------- main

int main(int argc, char **argv) {
  int i = 1;
  snprintf(lib, sizeof lib, "%s", argv[0]);
  char *sl = strrchr(lib, '/');
  if (sl) snprintf(sl + 1, lib + sizeof lib - sl - 1, "libtau.dylib");
  else snprintf(lib, sizeof lib, "libtau.dylib");
  snprintf(tdl_bin, sizeof tdl_bin, "%.*stau-tdl", sl ? (int)(sl + 1 - lib) : 0, lib);  // (beside tau-live)
  snprintf(pdfmx_bin, sizeof pdfmx_bin, "%.*stau-pdfmx", sl ? (int)(sl + 1 - lib) : 0, lib);
  int use_pdfmx = 1, lua_presize = 1;
  for (; i < argc && argv[i][0] == '-' && strcmp(argv[i], "--"); i++) {
    if (!strcmp(argv[i], "--lib") && i + 1 < argc) snprintf(lib, sizeof lib, "%s", argv[++i]);
    else if (!strcmp(argv[i], "--snapshot-ms") && i + 1 < argc) snapshot_ms = atol(argv[++i]);
    else if (!strcmp(argv[i], "--finish") && i + 1 < argc) finish_every = !strcmp(argv[++i], "every");
    else if (!strcmp(argv[i], "--max-snapshots") && i + 1 < argc) max_snaps = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--hook")) hook = 1;
    else if (!strcmp(argv[i], "--serve")) {}  // (pdftex-live's flag: tau-live always serves)
    else if (!strcmp(argv[i], "--engine") && i + 1 < argc) engine_path = argv[++i];
    else if (!strcmp(argv[i], "--bibtex") && i + 1 < argc) snprintf(bibtex_bin, sizeof bibtex_bin, "%s", argv[++i]);
    else if (!strcmp(argv[i], "--biber") && i + 1 < argc) snprintf(biber_bin, sizeof biber_bin, "%s", argv[++i]);
    else if (!strcmp(argv[i], "--makeindex") && i + 1 < argc) snprintf(makeindex_bin, sizeof makeindex_bin, "%s", argv[++i]);
    else if (!strcmp(argv[i], "--max-runs") && i + 1 < argc) max_runs = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--state") && i + 1 < argc) snprintf(state_dir, sizeof state_dir, "%s", argv[++i]);
    else if (!strcmp(argv[i], "--no-para")) para = 0;
    else if (!strcmp(argv[i], "--no-pdfmx")) use_pdfmx = 0;
    else if (!strcmp(argv[i], "--no-presize")) lua_presize = 0;
    else if (!strcmp(argv[i], "--no-display-pages")) display_pages = 0;
    else if (!strcmp(argv[i], "--no-first-finish")) first_finish = 0;
    else if (!strcmp(argv[i], "--first-snapshot-ms") && i + 1 < argc) first_sparse_ms = atol(argv[++i]);
    else if (!strcmp(argv[i], "--park") && i + 1 < argc) snprintf(park_sock, sizeof park_sock, "%s", argv[++i]);
    else if (!strcmp(argv[i], "--parked") && i + 1 < argc) snprintf(parked_sock, sizeof parked_sock, "%s", argv[++i]);
    else if (!strcmp(argv[i], "--dense") && i + 1 < argc) dense = atol(argv[++i]);
    else { fprintf(stderr, "tau-live: unknown option %s\n", argv[i]); return 2; }
  }
  static char *pk_args[4];
  if ((park_sock[0] && strlen(park_sock) >= sizeof(((struct sockaddr_un *)0)->sun_path)) ||
      (parked_sock[0] && strlen(parked_sock) >= sizeof(((struct sockaddr_un *)0)->sun_path))) {
    fprintf(stderr, "tau-live: socket path too long (a Unix socket's is at most 103 bytes)\n");
    return 2;
  }
  if (park_sock[0] && argc - i == 0 && engine_path) {  // --park needs no project: an empty one in a scratch directory
    static char tmpl[1100];
    const char *td = getenv("TMPDIR");
    snprintf(tmpl, sizeof tmpl, "%s/tau-park-XXXXXX", td && *td ? td : "/tmp");
    if (!mkdtemp(tmpl)) die("mkdtemp");
    static char emp[1200];
    snprintf(emp, sizeof emp, "%s/empty", tmpl);
    mkdir(emp, 0755);
    pk_args[0] = emp, pk_args[1] = "main.tex", pk_args[2] = tmpl;
    char **nv = calloc(argc + 4, sizeof *nv);
    memcpy(nv, argv, argc * sizeof *nv);
    nv[argc] = pk_args[0], nv[argc + 1] = pk_args[1], nv[argc + 2] = pk_args[2];
    argv = nv, argc += 3;
  }
  if (argc - i == 3 && engine_path) {  // pdftex-live's form: --engine PATH DIR MAIN OUT (the app's live driver)
    static char *a[8];
    int k = 0;
    a[k++] = (char *)engine_path;
    if (strstr(engine_path, "xe")) a[k++] = "-no-pdf";
    a[k++] = "-interaction=batchmode";
    a[k++] = "-synctex=-1";
    a[k++] = argv[i + 1];
    a[k] = NULL;
    static char *argv2[16];
    argv2[0] = argv[i], argv2[1] = argv[i + 1], argv2[2] = argv[i + 2], argv2[3] = "--";
    memcpy(argv2 + 4, a, (k + 1) * sizeof *a);
    argv = argv2, argc = 4 + k, i = 0;
    hook = 1;
  }
  if (argc - i < 5 || strcmp(argv[i + 3], "--")) {
    fprintf(stderr, "usage: tau-live [options] DIR MAIN OUT -- ENGINE ARGS...\n"
                    "       tau-live [--serve] --engine PATH [options] DIR MAIN OUT\n");
    return 2;
  }
  if (!realpath(argv[i], dir)) die(argv[i]);
  snprintf(mainf, sizeof mainf, "%s", argv[i + 1]);
  mkdir(argv[i + 2], 0755);
  if (!realpath(argv[i + 2], outdir)) die(argv[i + 2]);
  eng_argv = argv + i + 4;
  if (!bibtex_bin[0]) {  // BibTeX beside the engine (TeX Live's layout), if there
    snprintf(bibtex_bin, sizeof bibtex_bin, "%s", eng_argv[0]);
    char *sl = strrchr(bibtex_bin, '/');
    if (sl) strcpy(sl + 1, "bibtex");
    if (access(bibtex_bin, X_OK)) bibtex_bin[0] = 0;
  }
  if (hook) {  // the TeX side: a signal after every shipout, injected on the command line (docs/universal.md)
    int n = 0;
    while (eng_argv[n]) n++;
    char **a = calloc(n + 1, sizeof *a);
    memcpy(a, eng_argv, n * sizeof *a);
    const char *sig =
        strstr(a[0], "lua") ? "\\directlua{lfs.attributes(\"/.taudot/#1\")}"
        : strstr(a[0], "xe") ? "\\filesize{/.taudot/#1}"
                             : "\\pdffilesize{/.taudot/#1}";
    // The paragraph pass's macros, defined once here so a pass tokenizes almost nothing (docs/universal.md).
    // \taudotpg is defined only by a pass's flush: its output routine tests it to tell its own break.
    static const char *pass_macros =
        "\\def\\taudotx{\\dimen0=\\oddsidemargin\\csname if@twoside\\endcsname\\ifodd\\count0 \\else"
        "\\dimen0=\\evensidemargin\\fi\\fi\\csname if@twocolumn\\endcsname\\csname if@firstcolumn\\endcsname\\else"
        "\\advance\\dimen0\\dimexpr\\textwidth-\\columnwidth\\relax\\fi\\fi}"
        "\\def\\taudotgrab{\\gdef\\taudotown{1}\\setbox0\\vbox{\\unvbox255 \\global\\setbox2\\vbox{}\\global\\let\\taudotok=T"
        "\\count255=0\\taudotpg\\relax\\loop\\ifnum\\count255>0 \\ifnum\\lastnodetype=1 "
        "\\setbox4\\lastbox\\dimen2=\\ht4 \\skip0=\\lastskip\\unskip\\unpenalty"
        "\\global\\setbox2\\vbox{\\vskip\\skip0\\box4\\unvbox2}"
        "\\advance\\count255-1 \\else\\global\\let\\taudotok=F\\count255=0 \\fi\\repeat"
        // the lines' geometry for the driver: first baseline below the shipped page's top (less 1in), the span from
        // the first line's top to the last one's bottom, the first line's height (sp)
        // shipped down to \taudotyb (the old first baseline, sp) and across to \taudotxb (the old lines' left edge, sp:
        // \lastbox dropped their shift) when the driver knows them
        "\\if T\\taudotok\\xdef\\taudotk{\\ifx\\taudotyb\\empty 0pt\\else"
        "\\the\\dimexpr\\taudotyb sp-\\voffset-\\skip0-\\dimen2\\relax\\fi}"
        "\\xdef\\taudotg{-g\\number\\dimexpr\\voffset+\\taudotk+\\skip0+\\dimen2\\relax x"
        "\\number\\dimexpr\\ht2+\\dp2-\\skip0\\relax x\\number\\dimen2}\\fi}\\taudotmark{2}\\taudotx"
        "\\if T\\taudotok\\csname tex_shipout:D\\endcsname\\vbox{\\kern\\taudotk\\moveright"
        "\\ifx\\taudotxb\\empty\\dimen0\\else\\dimexpr\\taudotxb sp-\\hoffset\\relax\\fi\\box2}\\taudotmark{3}"
        "\\else\\shipout\\vbox{\\moveright\\dimen0\\vbox{\\unvbox0\\unvbox2}}\\fi\\taudotpad\\taudotmark{5}}"
        "\\def\\taudotpage{\\taudotx\\shipout\\vbox{\\moveright\\dimen0\\vbox{\\unvbox255}}}"
        "\\def\\taudotout{\\ifnum\\outputpenalty<-10000 \\the\\toks255 \\else"
        "\\xdef\\taudotn{\\the\\numexpr\\taudotn+1}\\ifdefined\\taudotpg\\taudotgrab\\else\\taudotpage\\fi"
        "\\deadcycles=0 \\taudotmark{6}\\fi}"
        "\\def\\taudotflush{\\taudotmark{0}\\par\\taudotmark{1}\\edef\\taudotpg{\\the\\prevgraf}\\penalty-10000 "
        "\\taudotmark{4}\\taudotsig{stop/\\taudotpg-\\taudotn-\\taudotown\\taudotg}}";
    // XeTeX keeps up to dvi_buf_size (16 KiB) of its output in memory: a page of padding pushes the pass's out
    static char pad[17300];
    if (strstr(a[0], "xe")) {
      strcpy(pad, "\\def\\taudotpad{\\csname tex_shipout:D\\endcsname\\hbox{\\special{");
      size_t l = strlen(pad);
      memset(pad + l, 'x', 17000);
      strcpy(pad + l + 17000, "}}}");
    } else
      strcpy(pad, "\\def\\taudotpad{}");
    // LuaTeX: every node it frees sets its entry of the node properties table (luaotfload turns them on) to nil;
    // for an absent key Lua inserts it and, the table being nearly empty, rehashes over and over: ~18% of a LuaLaTeX
    // run. An array part over the node indices (filled, then emptied: the same empty table to every reader) makes
    // those writes plain stores. Same output (checked byte for byte), a run ~19% faster.
    const char *presize = strstr(a[0], "lua") && lua_presize
                              ? "\\directlua{local t=node.direct.get_properties_table() for i=1,1048576 do t[i]=false end "
                                "for i=1,1048576 do t[i]=nil end}"
                              : "";
    static char inj[24576];
    snprintf(inj, sizeof inj,
             "%s\\def\\taudotsig#1{%s}\\AddToHook{shipout/after}{\\taudotsig{ship/\\the\\ReadonlyShipoutCounter}}"
             "%s%s%s\\csname @@input\\endcsname %s", presize, sig, pass_macros, pad,
             getenv("TAU_PHASES") ? "\\def\\taudotmark#1{\\taudotsig{t/#1}}" : "\\def\\taudotmark#1{}", a[n - 1]);
    // the parked form (tau-live --park, and sessions that fork from it): the main file's name read at run time (\space
    // ends the name, as the end of the line does after a literal one)
    static char injp[24576];
    snprintf(injp, sizeof injp,
             "%s\\def\\taudotsig#1{%s}\\AddToHook{shipout/after}{\\taudotsig{ship/\\the\\ReadonlyShipoutCounter}}"
             "%s%s%s{\\endlinechar=-1 \\openin15=/.taudot/main.tex \\global\\readline15 to\\taudotmain"
             "\\closein15}%s\\csname @@input\\endcsname\\taudotmain\\space", presize, sig, pass_macros, pad,
             getenv("TAU_PHASES") ? "\\def\\taudotmark#1{\\taudotsig{t/#1}}" : "\\def\\taudotmark#1{}",
             getenv("TAU_ALIAS_DEBUG") ? "\\immediate\\write16{TAUMAIN[\\taudotmain]}" : "");
    a[n - 1] = inj;
    eng_argv = a;
    park_argv = calloc(n + 1, sizeof *park_argv);
    memcpy(park_argv, a, n * sizeof *a);
    park_argv[n - 1] = injp;
    // what a parked engine was started with: a session forks from it only if all of it is the same
    uint64_t h = 14695981039346656037ULL;
    for (int k = 0; k < n; k++) h = fnv1a(fnv1a(h, park_argv[k], strlen(park_argv[k])), "\x01", 1);
    h = fnv1a(h, lib, strlen(lib));
    static const char *keys[] = {"TEXMFCNF", "TEXFORMATS", "TEXINPUTS", "TAU_TLROOT", "TEXSTORE_ROOT", "TEXSTORE_URL",
                                 "TEXSTORE_IMAGE", "TAU_FETCH", "SOURCE_DATE_EPOCH", "FORCE_SOURCE_DATE", "TAU_WARM_QOS",
                                 "TAU_WARM_TOUCH", "TAU_WARM_PIPE", "TAU_PHASES", NULL};
    for (int k = 0; keys[k]; k++) {
      const char *v = getenv(keys[k]);
      h = fnv1a(fnv1a(h, keys[k], strlen(keys[k])), v ? v : "\x02", v ? strlen(v) + 1 : 1);
    }
    snprintf(park_sig, sizeof park_sig, "%016llx", (unsigned long long)h);
  }
  snprintf(work, sizeof work, "%s/work", outdir);
  snprintf(tdir, sizeof tdir, "%s/t", outdir);
  char cmd[8192];
  snprintf(cmd, sizeof cmd, "rm -rf '%s' '%s' && cp -c -R '%s' '%s' 2>/dev/null || cp -R '%s' '%s'", work, tdir, dir,
           work, dir, work);
  if (system(cmd)) die("copy project");
  mkdir(tdir, 0755);
  {  // the engine's command line, for checks (uni.py prelude: the prelude must leave the output byte-identical)
    char cp[4200];
    snprintf(cp, sizeof cp, "%s/cmdline", tdir);
    FILE *f = fopen(cp, "w");
    for (int i = 0; f && eng_argv[i]; i++) fprintf(f, "%s%c", eng_argv[i], 0);
    if (f) fclose(f);
  }
  int p[2];
  if (pipe(p)) die("pipe");
  msg_r = p[0], msg_w = p[1];
  fcntl(msg_r, F_SETFD, FD_CLOEXEC);
  if (pipe(p)) die("pipe");
  life_r = p[0], life_w = p[1];
  fcntl(life_w, F_SETFD, FD_CLOEXEC);
  signal(SIGPIPE, SIG_IGN);
  if (getenv("TAU_LIVE_LOG")) dbg = fopen(getenv("TAU_LIVE_LOG"), "w");
  if (park_sock[0]) return park_loop();
  restore_state();
  if (hook && para) reader_start();  // (the paragraph preview's reader, ready before the first pass)
  if (use_pdfmx && !strcmp(out_ext(), "xdv")) pdfmx_start();  // (warms kpathsea while the engine starts)
  {
    fprintf(stdout, "{\"ev\":\"hello\",\"protocol\":1,\"engine\":");
    jstr(stdout, eng_argv[0], strlen(eng_argv[0]));
    const char *img = getenv("TEXSTORE_IMAGE");
    if (img) { fputs(",\"image\":", stdout); jstr(stdout, img, strlen(img)); }
    fprintf(stdout, ",\"driver\":\"tau-live\"}\n");
    fflush(stdout);
  }
  seq = 0;
  t_apply = now_us();
  spawn_engine();
  emit("{\"ev\":\"run\",\"seq\":0,\"run\":1,\"applied\":0,\"why\":\"open\",\"from_page\":0}");
  static char ibuf[1 << 22], mbuf[1 << 16];
  size_t ilen = 0, mlen = 0;
  for (;;) {
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
    if (ndoomed && (pass.seq != seq || (pass_out_seq == seq && !njobs) || now_us() - doomed_at > 50000)) kill_doomed();
    display_pump();  // (display pages held while the pass ran: after its reader request)
    struct pollfd pf[4] = {{0, POLLIN, 0}, {msg_r, POLLIN, 0}, {reader_out, POLLIN, 0}, {pdfmx_out, POLLIN, 0}};
    if (poll(pf, 4, ndoomed || (dq_seq == seq && dq_at < dq_n && display_seq != seq) ? 10 : 200) < 0 && errno != EINTR) die("poll");  // (negative fds are skipped)
    if (pdfmx_out >= 0 && (pf[3].revents & (POLLIN | POLLHUP))) {
      static char xbuf[4096];
      static size_t xlen;
      ssize_t r = read(pdfmx_out, xbuf + xlen, sizeof xbuf - xlen - 1);
      if (r <= 0) {  // the converter died: pending events go out without pdf_path (the client converts)
        pdfmx_stop();
        xlen = 0;
      } else {
        xlen += r;
        char *s = xbuf, *nl;
        while ((nl = memchr(s, '\n', xbuf + xlen - s))) {
          *nl = 0;
          pdfmx_answer(s);
          s = nl + 1;
        }
        xlen = xbuf + xlen - s;
        memmove(xbuf, s, xlen);
      }
    }
    if (reader_out >= 0 && (pf[2].revents & (POLLIN | POLLHUP))) {
      static char rbuf[65536];
      static size_t rlen;
      ssize_t r = read(reader_out, rbuf + rlen, sizeof rbuf - rlen - 1);
      if (r <= 0) {  // the reader died: its requests get no preview; the next pass starts another
        for (int i = 0; i < njobs; i++) if (jobs[i].seq == seq) para_none(seq, "reader", 0, 0, NULL);
        reader_stop();
        rlen = 0;
      } else {
        rlen += r;
        char *s = rbuf, *nl;
        while ((nl = memchr(s, '\n', rbuf + rlen - s))) {
          *nl = 0;
          reader_answer(s);
          s = nl + 1;
        }
        rlen = rbuf + rlen - s;
        memmove(rbuf, s, rlen);
      }
    }
    if (pf[1].revents & POLLIN) {
      ssize_t r = read(msg_r, mbuf + mlen, sizeof mbuf - mlen - 1);
      if (r > 0) {
        mlen += r;
        char *s = mbuf, *nl;
        while ((nl = memchr(s, '\n', mbuf + mlen - s))) {
          *nl = 0;
          on_msg(s);
          s = nl + 1;
        }
        replay();
        mlen = mbuf + mlen - s;
        memmove(mbuf, s, mlen);
      }
    }
    if (pf[0].revents & (POLLIN | POLLHUP)) {
      ssize_t r = read(0, ibuf + ilen, sizeof ibuf - ilen - 1);
      if (r <= 0) break;
      ilen += r;
      char *s = ibuf, *nl;
      while ((nl = memchr(s, '\n', ibuf + ilen - s))) {
        *nl = 0;
        on_cmd(s);
        s = nl + 1;
      }
      ilen = ibuf + ilen - s;
      memmove(ibuf, s, ilen);
    }
  }
  kill_all();
  reader_stop();
  pdfmx_stop();
  keep_state();
  close(life_w);
  return 0;
}
