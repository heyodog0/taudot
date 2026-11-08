/* para.c: --serve's paragraph preview, the driver's side (docs/live-protocol.md, `para`). #included by serve.c.
   Copyright 2026 Ryan Truong. GPL-2.0-or-later.

   The engine (patch 0011) leaves a paragraph snapshot at the start of the paragraph being edited, with a warm child
   parked beside it (Q, W). On every edit after that offset, in that file, the driver hands the warm child the file's
   new text (pgo) and wakes it; it typesets that paragraph alone and writes its lines (H, OUT/para-<n>.out): their
   metrics, the content stream pdfTeX writes for them and the fonts it names. The runner of each compile says where
   the paragraph's old lines are on its pages (A). From those this file makes the `para` event: the new lines as a
   display list placed over the old ones in the PDF on screen, and whether the page around them is unchanged. */

#define P_NANC 32
struct pline { int page, x, y, w, h, d; };
struct panchor { int seq; long off; int n; int pw, ph, seg; struct pline *l; };
static struct panchor p_anc[P_NANC];
static int p_nanc_next;

/* the paragraph snapshot (at most one) */
static struct { int pid; uint64_t start; int seq; long off; char rel[PATH_MAX]; int warm; uint64_t warm_start; } ps;

/* edits since a run started, to tell whether a paragraph snapshot that run made still holds the text before it */
#define P_NCHG 1024
static struct { long applied; char rel[256]; long k; } p_chg[P_NCHG];
static long p_nchg;
#define P_NRUN 256
static long p_run_applied[P_NRUN];  /* by runseq % P_NRUN: `applied` when it started */

/* the PDF on screen (the newest announced): its run, path, pages; and for each page, the run whose PDF shows it (a
   PDF finished early stops before the pages after the edit, which stay from an older one) */
static int p_shown_seq = -1, p_shown_pages;
static int p_run_pdf_pages;  /* pages in this compile's newest PDF */
static char p_shown_pdf[PATH_MAX];
static int *p_page_seq, p_npage_seq;
#define P_NPDF 32
static struct { int seq; char path[PATH_MAX]; } p_pdfs[P_NPDF];
static int p_npdfs;

/* the go in flight and the one wanted next */
static int p_busy;               /* the warm child told to go (pid), or 0 */
static int p_want;               /* an edit to show once the warm child is ready */
static char p_want_rel[PATH_MAX];
static long p_want_k, p_want_applied;
static uint64_t p_want_t;
static int p_go_n;
/* each go in flight (passes can overlap: the next warm child is ready while one runs); `p_go` is the one an event
   is being made for */
struct pgo { long k, applied, off; uint64_t t_cmd, t_sent; int seq, n; };
static struct pgo p_gos[8], p_go;
static int p_shown_go;           /* the newest go announced: an older one finishing later is dropped */
static long p_stats[4];          /* go, exact, provisional, none (for tests and the log) */

static void p_kill_snap(void) {
  if (ps.pid) sig(ps.pid, ps.start, SIGKILL);  /* its warm child follows it (kqueue on its parent) */
  if (ps.warm) sig(ps.warm, ps.warm_start, SIGKILL);
  memset(&ps, 0, sizeof ps);
}

/* A compile starts at runseq `seq` for an edit at k of rel: the window for a paragraph snapshot (the line after the
   last blank line before k, at most 32 KB back) and the one the driver has, for ctl. */
static long p_window(const char *rel, long k) {
  struct text *t = rel ? text_of(rel, 0) : NULL;
  if (!t || k < 0 || k > t->len) return -1;
  long lim = k > 32768 ? k - 32768 : 0, i = k, w = lim;
  while (i > 0 && t->buf[i - 1] != '\n') i--;  /* the edit's line start */
  for (long j = i - 1; j > lim; j--) {         /* back over lines, to one that is blank */
    if (t->buf[j - 1] != '\n') continue;
    long e = j;
    while (e < t->len && (t->buf[e] == ' ' || t->buf[e] == '\t' || t->buf[e] == '\r')) e++;
    if (e < t->len && t->buf[e] == '\n') { w = e + 1; break; }
  }
  return w;
}

static void para_compile(int seq, const char *rel, long k) {
  p_run_applied[seq % P_NRUN] = applied;
  p_run_pdf_pages = 0;
  ctl_pwin = ctl_phave = -1;
  long w = p_window(rel, k);
  if (w < 0) return;
  ctl_pwin = w;
  if (ps.pid && !strcmp(ps.rel, rel) && ps.off <= k && ps.off >= w) ctl_phave = ps.off;
}

static void para_rerun(void) { ctl_pwin = ctl_phave = -1; }

static void p_note_change(const char *rel, long k) {
  long i = p_nchg++ % P_NCHG;
  p_chg[i].applied = applied;
  snprintf(p_chg[i].rel, sizeof p_chg[i].rel, "%s", rel);
  p_chg[i].k = k;
}

/* Did an edit since run `seq` began change rel before `off`, or another file? (-1: can't tell, so yes) */
static int p_changed_before(int seq, const char *rel, long off) {
  long a0 = p_run_applied[seq % P_NRUN];
  long first = p_nchg > P_NCHG ? p_nchg - P_NCHG : 0;
  if (p_nchg > P_NCHG && p_chg[first % P_NCHG].applied > a0 + 1) return 1;
  for (long n = first; n < p_nchg; n++) {
    long i = n % P_NCHG;
    if (p_chg[i].applied <= a0) continue;
    if (strcmp(p_chg[i].rel, rel) || p_chg[i].k < off) return 1;
  }
  return 0;
}

static void p_fire(void);

/* The PDF on screen changed (ev_pdf). */
static void para_shown(const char *pdf, int pages) {
  if (p_shown_seq != cur_runseq) p_run_pdf_pages = 0;
  if (pages > p_run_pdf_pages) p_run_pdf_pages = pages;
  p_shown_seq = cur_runseq;
  p_shown_pages = pages;
  snprintf(p_shown_pdf, sizeof p_shown_pdf, "%s", pdf);
  if (pages > p_npage_seq) { p_page_seq = realloc(p_page_seq, pages * sizeof *p_page_seq); p_npage_seq = pages; }
  for (int i = 0; i < pages; i++) p_page_seq[i] = cur_runseq;
  int k = p_npdfs++ % P_NPDF;
  p_pdfs[k].seq = cur_runseq;
  snprintf(p_pdfs[k].path, sizeof p_pdfs[k].path, "%s", pdf);
}

/* The anchor for the paragraph at `off` as it is on screen: from the run whose PDF shows its page; and that PDF. */
static struct panchor *p_anchor_shown(long off, const char **pdf) {
  struct panchor *best = NULL;
  for (int i = 0; i < P_NANC; i++) {
    struct panchor *a = &p_anc[i];
    if (!a->l || a->off != off || a->l[0].page >= p_npage_seq || p_page_seq[a->l[0].page] != a->seq) continue;
    if (!best || a->seq > best->seq) best = a;
  }
  *pdf = NULL;
  if (best)
    for (int i = 0; i < P_NPDF && i < p_npdfs; i++) if (p_pdfs[i].seq == best->seq) *pdf = p_pdfs[i].path;
  return best;
}

/* An edit at k of rel was read (time t): show its paragraph if the snapshot holds it, else drop a snapshot it
   invalidates. */
static void para_edit(const char *rel, long k, uint64_t t) {
  p_note_change(rel, k);
  if (ps.pid && (strcmp(ps.rel, rel) || k < ps.off)) p_kill_snap();
  if (!ps.pid) return;
  if (ps.off < p_window(rel, k)) return;  /* it holds an earlier paragraph: this edit's run leaves one for this */
  p_want = 1;
  snprintf(p_want_rel, sizeof p_want_rel, "%s", rel);
  p_want_k = k;
  p_want_applied = applied;
  p_want_t = t;
  p_fire();
}

static struct panchor *p_anchor_for(int seq, long off);
static void p_fire(void) {
  if (!p_want || !ps.pid || !ps.warm) return;
  struct text *t = text_of(p_want_rel, 0);
  if (!t) { p_want = 0; return; }
  char text[PATH_MAX], go[PATH_MAX], tmp[PATH_MAX], line[PATH_MAX + 64];
  int n = ++p_go_n;
  snprintf(text, sizeof text, "%s/ptext-%d", s_out, n % 4);  /* a few in turn: a child reads its own right away */
  spit(text, t->buf, t->len);
  snprintf(go, sizeof go, "%s/pgo-%d", s_out, ps.pid);
  snprintf(tmp, sizeof tmp, "%s.tmp", go);
  /* where the paragraph's old lines are on the page on screen: the pass ships its lines there, on a page of that
     size, so its content stream has the page's own coordinates (glyphs land on the same subpixels) */
  const char *apdf;
  struct panchor *a = p_anchor_shown(ps.off, &apdf);
  int m = a && a->ph > 0
    ? snprintf(line, sizeof line, "%d %d %ld %s %d %d %d %d\n", n, ps.seq, p_want_k, text, a->l[0].x, a->l[0].y, a->pw, a->ph)
    : snprintf(line, sizeof line, "%d %d %ld %s\n", n, ps.seq, p_want_k, text);
  spit(tmp, line, m);
  rename(tmp, go);
  struct pgo *g = &p_gos[n % 8];
  g->k = p_want_k; g->applied = p_want_applied; g->off = ps.off; g->t_cmd = p_want_t; g->seq = ps.seq; g->n = n;
  g->t_sent = now_us();
  p_busy = ps.warm;
  sig(ps.warm, ps.warm_start, SIGUSR1);
  ps.warm = 0;  /* used: the snapshot forks the next (W) */
  p_want = 0;
  p_stats[0]++;
}

static struct panchor *p_anchor_for(int seq, long off) {
  for (int i = 0; i < P_NANC; i++)
    if (p_anc[i].l && p_anc[i].seq == seq && p_anc[i].off == off) return &p_anc[i];
  return NULL;
}

static void p_event_none(const char *why, uint64_t t_go, uint64_t t_lb);
static void p_event(const char *name, uint64_t t_go, uint64_t t_lb, uint64_t t_ship, uint64_t t_done);

/* Engine messages for the preview: Q, W, A, H. Returns 1 if it was one. */
static int p_debug = -1;
static int para_handle(char *m) {
  int a, b, c, d;
  if (p_debug < 0) p_debug = getenv("TAUDOT_PARA_DEBUG") != NULL;
  if (p_debug && strchr("QWAHD", m[0])) fprintf(stderr, "para: %.*s | shown %d off %ld\n", (int)strcspn(m, "\n"), m, p_shown_seq, ps.off);
  long off;
  char rel[PATH_MAX];
  if (m[0] == 'D') return 1;
  if (m[0] == 'Q') {
    if (sscanf(m, "Q %d %d %ld %1023s", &a, &b, &off, rel) != 4) return 1;
    uint64_t st = proc_start(a);
    if (p_changed_before(b, rel, off)) { sig(a, st, SIGKILL); return 1; }
    /* keep the one nearest the edit (a run can leave several, and they report in any order) */
    if (ps.pid && ps.pid != a && !strcmp(ps.rel, rel) && ps.off >= off) { sig(a, st, SIGKILL); return 1; }
    if (ps.pid && ps.pid != a) p_kill_snap();  /* a pass it is running finishes on its own */
    ps.pid = a; ps.start = st; ps.seq = b; ps.off = off; ps.warm = 0;
    snprintf(ps.rel, sizeof ps.rel, "%s", rel);
    return 1;
  }
  if (m[0] == 'W') {
    if (sscanf(m, "W %d %d", &a, &b) != 2) return 1;
    if (a != ps.pid) { sig(b, proc_start(b), SIGKILL); return 1; }
    ps.warm = b;
    ps.warm_start = proc_start(b);
    p_fire();
    return 1;
  }
  if (m[0] == 'A') {
    int pw = 0, ph = 0, seg = 0;
    if (sscanf(m, "A %d %d %ld %d %d %d %d %d", &a, &b, &off, &c, &d, &pw, &ph, &seg) < 5 || d <= 0) return 1;
    struct panchor *x = &p_anc[p_nanc_next++ % P_NANC];
    free(x->l);
    x->seq = b; x->off = off; x->n = 0; x->pw = pw; x->ph = ph; x->seg = seg;
    /* The edited paragraph's page is about to ship: if no PDF of this run has it, finish one right after (the run's
       first PDF can stop a page short of it, and under typing no later one comes before the next key). Its lines
       on screen are then this run's, so the next preview has their place. */
    if (b == cur_runseq && !c_idle && c > p_run_pdf_pages) held_sigs |= 1;
    x->l = calloc(d, sizeof *x->l);
    char *p = strchr(m, '\n');
    while (p && *++p && x->n < d) {
      struct pline *l = &x->l[x->n];
      if (sscanf(p, "%d %d %d %d %d %d", &l->page, &l->x, &l->y, &l->w, &l->h, &l->d) != 6) break;
      x->n++;
      p = strchr(p, '\n');
    }
    return 1;
  }
  if (m[0] == 'H') {
    char name[128], st[32];
    unsigned long long t0 = 0, t1 = 0, t2 = 0, t3 = 0;
    int n = sscanf(m, "H %d %d %d %127s %31s %llu %llu %llu %llu", &a, &b, &c, name, st, &t0, &t1, &t2, &t3);
    if (n < 5) return 1;
    if (a == p_busy) p_busy = 0;
    if (b <= p_shown_go || p_gos[b % 8].n != b) return 1;  /* older than the one shown */
    p_go = p_gos[b % 8];
    p_shown_go = b;
    if (!strcmp(name, "-")) p_event_none(st, p_go.t_sent, 0);
    else p_event(name, t0, t1, t2, t3);
    p_fire();
    return 1;
  }
  return 0;
}

static void para_forget(void) {
  p_kill_snap();
  p_busy = 0;
  p_want = 0;
}

/* ---- the para-<n>.out file ---- */

struct pnew { int shift, w, h, d, dy; };
struct pfont { int num, size, slant, extend, bc, nw; int *wd; char ff[PATH_MAX], enc[PATH_MAX], ps[256]; };
struct pout {
  int ins, mark, adjust, write, savepos, image, stretch, flt_lb, flt_ship, cpu_lb, cpu_ship, cpu_break;
  int n; struct pnew *l;
  int base0, total, width, hx, vy, pw, ph, seg, shaped;
  int nf; struct pfont *f;
  long clen; char *content;
};

static void pout_free(struct pout *o) {
  free(o->l);
  for (int i = 0; i < o->nf; i++) free(o->f[i].wd);
  free(o->f);
  free(o->content);
}

static int pout_read(const char *path, struct pout *o) {
  long len;
  memset(o, 0, sizeof *o);
  char *b = slurp(path, &len);
  if (!b) return -1;
  char *p = b, *end = b + len;
  int ok = 0;
  while (p < end) {
    char *nl = memchr(p, '\n', end - p);
    if (!nl) break;
    *nl = 0;
    if (!strncmp(p, "flags2 ", 7)) sscanf(p, "flags2 %d", &o->stretch);
    else if (!strncmp(p, "faults ", 7)) sscanf(p, "faults %d %d %d %d %d", &o->flt_lb, &o->flt_ship, &o->cpu_lb, &o->cpu_ship, &o->cpu_break);
    else if (!strncmp(p, "flags ", 6))
      sscanf(p, "flags %d %d %d %d %d %d", &o->ins, &o->mark, &o->adjust, &o->write, &o->savepos, &o->image);
    else if (!strncmp(p, "lines ", 6)) {
      sscanf(p, "lines %d", &o->n);
      o->l = calloc(o->n ? o->n : 1, sizeof *o->l);
      for (int i = 0; i < o->n; i++) {
        p = nl + 1;
        nl = memchr(p, '\n', end - p);
        if (!nl) goto out;
        *nl = 0;
        struct pnew *l = &o->l[i];
        sscanf(p, "%d %d %d %d %d", &l->shift, &l->w, &l->h, &l->d, &l->dy);
      }
    } else if (!strncmp(p, "page ", 5)) sscanf(p, "page %d %d %d", &o->base0, &o->total, &o->width);
    else if (!strncmp(p, "seg ", 4)) sscanf(p, "seg %d %d", &o->seg, &o->shaped);
    else if (!strncmp(p, "place ", 6)) sscanf(p, "place %d %d %d %d", &o->hx, &o->vy, &o->pw, &o->ph);
    else if (!strncmp(p, "font ", 5)) {
      o->f = realloc(o->f, (o->nf + 1) * sizeof *o->f);
      struct pfont *f = &o->f[o->nf++];
      memset(f, 0, sizeof *f);
      sscanf(p, "font %d %d %d %d %d %d %1023s %1023s %255s", &f->num, &f->size, &f->slant, &f->extend, &f->bc, &f->nw,
             f->ff, f->enc, f->ps);
      p = nl + 1;
      nl = memchr(p, '\n', end - p);
      if (!nl) goto out;
      *nl = 0;
      f->wd = calloc(f->nw ? f->nw : 1, sizeof *f->wd);
      char *q = p;
      for (int i = 0; i < f->nw; i++) f->wd[i] = (int)strtol(q, &q, 10);
    } else if (!strncmp(p, "content ", 8)) {
      o->clen = atol(p + 8);
      if (nl + 1 + o->clen > end) goto out;
      o->content = malloc(o->clen + 1);
      memcpy(o->content, nl + 1, o->clen);
      o->content[o->clen] = 0;
      ok = 1;
      break;
    }
    p = nl + 1;
  }
out:
  free(b);
  return ok ? 0 : -1;
}

/* ---- events ---- */

static void p_head(const char *state, const char *why) {
  fprintf(evout, "{\"ev\":\"para\",\"go\":%d,\"applied\":%ld,\"file\":", p_go.n, p_go.applied);
  jstr(evout, ps.rel[0] ? ps.rel : p_want_rel);
  fprintf(evout, ",\"state\":\"%s\"", state);
  if (why) { fputs(",\"why\":", evout); jstr(evout, why); }
}

static void p_event_none(const char *why, uint64_t t_go, uint64_t t_lb) {
  (void)t_go; (void)t_lb;
  p_stats[3]++;
  p_head("none", why);
  fprintf(evout, ",\"us\":%llu}\n", (unsigned long long)(now_us() - p_go.t_cmd));
  fflush(evout);
}

static double sp2bp(double sp) { return sp / 65536.0 * 72.0 / 72.27; }

#include "paradraw.c"

static void p_event(const char *name, uint64_t t_go, uint64_t t_lb, uint64_t t_ship, uint64_t t_done) {
  char path[PATH_MAX];
  struct pout o;
  snprintf(path, sizeof path, "%s/%s", s_out, name);
  int r = pout_read(path, &o);
  unlink(path);
  if (r) { p_event_none("read", t_go, t_lb); return; }
  const char *why = NULL;
  int exact = 1;
  const char *apdf = NULL;
  struct panchor *a = p_anchor_shown(p_go.off, &apdf);
  if (!a || !apdf) why = "noanchor";
  else if (a->seg && o.seg && a->seg != o.seg) why = "segment";  /* another part of the paragraph (a display between) */
  else {
    for (int i = 1; i < a->n; i++)  /* across pages, or columns (a line above the one before it) */
      if (a->l[i].page != a->l[0].page || a->l[i].y <= a->l[i - 1].y) why = "split";
  }
  if (!why && o.ins) why = "insert";
  if (!why && o.shaped) why = "parshape";  /* wrapfig, lettrine, \hangindent: other things share the lines' space */
  if (!why && o.image) why = "image";
  if (!why && o.n == 0) why = "empty";
  if (why) { pout_free(&o); p_event_none(why, t_go, t_lb); return; }
  /* the same layout around it? */
  const char *prov = NULL;
  if (o.n != a->n) prov = "lines";
  else
    for (int i = 0; i < o.n && !prov; i++) {
      if (o.l[i].h != a->l[i].h || o.l[i].d != a->l[i].d || o.l[i].w != a->l[i].w) prov = "heights";
      else if (o.l[i].dy != a->l[i].y - a->l[0].y) prov = "spacing";
      else if (a->l[i].x - a->l[0].x != o.l[i].shift - o.l[0].shift) prov = "indent";
    }
  if (!prov && o.mark) prov = "mark";
  if (!prov && o.adjust) prov = "vadjust";
  if (!prov && o.write) prov = "write";
  if (!prov && o.savepos) prov = "savepos";
  if (!prov && o.stretch && o.n != a->n) prov = "glue";
  exact = !prov;
  char dl[PATH_MAX];
  snprintf(dl, sizeof dl, "%s/para-%d.tdl", s_out, p_go.n % 4);
  uint64_t t_dl0 = now_us();
  char pdfp[PATH_MAX];
  snprintf(pdfp, sizeof pdfp, "%s/para-%d.pdf", s_out, p_go.n % 4);
  const char *derr = p_draw(&o, a, dl, pdfp);
  uint64_t t_dl1 = now_us();
  if (derr) { pout_free(&o); p_event_none(derr, t_go, t_lb); return; }
  p_stats[exact ? 1 : 2]++;
  p_head(exact ? "exact" : "provisional", prov);
  fprintf(evout, ",\"pdf\":");
  jstr(evout, apdf);
  fprintf(evout, ",\"page\":%d,\"path\":", a->l[0].page);
  jstr(evout, dl);
  fputs(",\"overlay\":", evout);
  jstr(evout, pdfp);
  fprintf(evout, ",\"origin\":[%.4f,%.4f]", sp2bp(a->l[0].x - o.l[0].shift - o.hx), sp2bp(a->l[0].y - o.base0 - o.vy));
  /* what to paint paper over: the old lines and the new, a little past their boxes (round letters overshoot the
     baseline and the x-height, italics overhang), but never past halfway to the next line */
  fputs(",\"erase\":[", evout);
  int ne = a->n + o.n;
  double (*er)[4] = calloc(ne, sizeof *er);
  for (int i = 0; i < a->n; i++) {
    struct pline *l = &a->l[i];
    er[i][0] = l->x; er[i][1] = l->y - l->h; er[i][2] = l->x + l->w; er[i][3] = l->y + l->d;
  }
  for (int i = 0; i < o.n; i++) {
    struct pnew *l = &o.l[i];
    double x = a->l[0].x - o.l[0].shift + l->shift, y = a->l[0].y + l->dy;
    double *r = er[a->n + i];
    r[0] = x; r[1] = y - l->h; r[2] = x + l->w; r[3] = y + l->d;
  }
  double pad = 65536.0 * 72.27 / 72.0;  /* 1 bp in sp */
  for (int i = 0; i < ne; i++) {
    double up = 0.6 * pad, down = 0.6 * pad;
    for (int j = 0; j < ne; j++) {
      if (j == i || er[j][2] < er[i][0] || er[j][0] > er[i][2]) continue;
      if (er[j][3] <= er[i][1] && (er[i][1] - er[j][3]) / 2 < up) up = (er[i][1] - er[j][3]) / 2;
      if (er[j][1] >= er[i][3] && (er[j][1] - er[i][3]) / 2 < down) down = (er[j][1] - er[i][3]) / 2;
    }
    fprintf(evout, "%s[%.3f,%.3f,%.3f,%.3f]", i ? "," : "", sp2bp(er[i][0] - pad), sp2bp(er[i][1] - up),
            sp2bp(er[i][2] + pad), sp2bp(er[i][3] + down));
  }
  free(er);
  fprintf(evout, "],\"lines\":%d,\"old_lines\":%d", o.n, a->n);
  /* times: engine (go to lines broken, to lines shipped, to written), the driver's display list, key to event */
  fprintf(evout, ",\"faults\":[%d,%d],\"engine_cpu_us\":%d,\"ship_cpu_us\":%d,\"break_cpu_us\":%d", o.flt_lb, o.flt_ship, o.cpu_lb, o.cpu_ship, o.cpu_break);
  fprintf(evout, ",\"engine_us\":%llu,\"ship_us\":%llu,\"write_us\":%llu,\"wake_us\":%llu,\"draw_us\":%llu,\"us\":%llu}\n",
          (unsigned long long)(t_lb - t_go), (unsigned long long)(t_ship - t_lb), (unsigned long long)(t_done - t_ship),
          (unsigned long long)(t_go > p_go.t_sent ? t_go - p_go.t_sent : 0), (unsigned long long)(t_dl1 - t_dl0),
          (unsigned long long)(now_us() - p_go.t_cmd));
  fflush(evout);
  pout_free(&o);
}
