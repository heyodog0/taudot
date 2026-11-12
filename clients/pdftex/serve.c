/* serve.c: pdftex-live --serve, the app's interactive mode (docs/live-protocol.md, by livepane).
   Copyright 2026 Ryan Truong. GPL-2.0-or-later. #included by live.c (it uses the driver's state and rule).

   pdftex-live --serve [--engine PATH] [--fmt NAME] [--snapshot-ms N] [--bibtex PATH] [--max-runs N]
                       [--synctex N] [--state STATE] DIR MAIN.tex OUT

   DIR is never written. The engine runs on OUT/work, a copy of DIR made with APFS clones (`cp -c`), where edits,
   latexmk's written files (.aux, .bbl) and BibTeX's go; STATE fills in missing .aux/.bbl/.blg at start and keeps
   them at exit. Commands come on stdin, one JSON array a line; events go to stdout, one JSON object a line. The
   SyncTeX beside each PDF is plain (`-synctex=-1`) unless --synctex says otherwise, so a PDF never waits on a
   gzip. */

#include <spawn.h>
#include <pthread.h>
#include <sys/qos.h>
extern char **environ;

/* ---- JSON ---- */

static void jstr(FILE *f, const char *s) {
  fputc('"', f);
  for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
    if (*p == '"' || *p == '\\') fprintf(f, "\\%c", *p);
    else if (*p == '\n') fputs("\\n", f);
    else if (*p == '\t') fputs("\\t", f);
    else if (*p == '\r') fputs("\\r", f);
    else if (*p < 0x20) fprintf(f, "\\u%04x", *p);
    else fputc(*p, f);
  }
  fputc('"', f);
}

/* One command: ["name", args...]. Strings come back unescaped (UTF-8), with their byte length; numbers as long. */
#define MAXARG 6
struct jval { int is_str; char *s; long len; long n; };
struct cmd { int argc; struct jval a[MAXARG]; };

static int utf8_put(char *o, unsigned cp) {
  if (cp < 0x80) { o[0] = cp; return 1; }
  if (cp < 0x800) { o[0] = 0xC0 | cp >> 6; o[1] = 0x80 | (cp & 63); return 2; }
  if (cp < 0x10000) { o[0] = 0xE0 | cp >> 12; o[1] = 0x80 | (cp >> 6 & 63); o[2] = 0x80 | (cp & 63); return 3; }
  o[0] = 0xF0 | cp >> 18; o[1] = 0x80 | (cp >> 12 & 63); o[2] = 0x80 | (cp >> 6 & 63); o[3] = 0x80 | (cp & 63);
  return 4;
}

static unsigned hex4(const char *p) {
  unsigned v = 0;
  for (int i = 0; i < 4; i++) {
    char c = p[i];
    v = v * 16 + (c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : 0);
  }
  return v;
}

static int parse_cmd(const char *p, struct cmd *c) {
  memset(c, 0, sizeof *c);
  while (*p == ' ') p++;
  if (*p++ != '[') return -1;
  for (;;) {
    while (*p == ' ' || *p == ',') p++;
    if (*p == ']') return c->argc > 0 && c->a[0].is_str ? 0 : -1;
    if (c->argc == MAXARG) return -1;
    struct jval *v = &c->a[c->argc++];
    if (*p == '"') {
      size_t cap = 64, n = 0;
      char *o = malloc(cap);
      for (p++; *p && *p != '"'; p++) {
        if (n + 8 > cap) { cap *= 2; o = realloc(o, cap); }
        if (*p != '\\') { o[n++] = *p; continue; }
        p++;
        switch (*p) {
        case 'n': o[n++] = '\n'; break;
        case 't': o[n++] = '\t'; break;
        case 'r': o[n++] = '\r'; break;
        case 'b': o[n++] = '\b'; break;
        case 'f': o[n++] = '\f'; break;
        case 'u': {
          if (strlen(p) < 5) { free(o); return -1; }
          unsigned cp = hex4(p + 1);
          p += 4;
          if (cp >= 0xD800 && cp < 0xDC00 && p[1] == '\\' && p[2] == 'u') {
            unsigned lo = hex4(p + 3);
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            p += 6;
          }
          n += utf8_put(o + n, cp);
          break;
        }
        case 0: free(o); return -1;
        default: o[n++] = *p;
        }
      }
      if (*p != '"') { free(o); return -1; }
      p++;
      o[n] = 0;
      v->is_str = 1; v->s = o; v->len = (long)n;
    } else if (*p == '-' || (*p >= '0' && *p <= '9')) {
      char *e;
      v->n = strtol(p, &e, 10);
      p = e;
      while (*p == '.' || (*p >= '0' && *p <= '9') || *p == 'e' || *p == 'E' || *p == '+' || *p == '-') p++;
    } else return -1;
  }
}

static void free_cmd(struct cmd *c) {
  for (int i = 0; i < c->argc; i++) free(c->a[i].s);
}

/* ---- events ---- */

static FILE *evout;

static void ev_error(const char *what, const char *msg) {
  fputs("{\"ev\":\"error\",\"what\":", evout); jstr(evout, what);
  fputs(",\"message\":", evout); jstr(evout, msg); fputs("}\n", evout);
  fflush(evout);
}

/* Files named in events stay until three newer of the same kind are announced. */
#define KEEP 4
struct ring { char *paths[KEEP][3]; int n; };
static struct ring ring_pdf, ring_blg;
static void ring_add(struct ring *r, const char *a, const char *b, const char *c) {
  int i = r->n % KEEP;
  if (r->n >= KEEP)
    for (int k = 0; k < 3; k++) if (r->paths[i][k]) { unlink(r->paths[i][k]); free(r->paths[i][k]); r->paths[i][k] = NULL; }
  r->paths[i][0] = a ? strdup(a) : NULL;
  r->paths[i][1] = b ? strdup(b) : NULL;
  r->paths[i][2] = c ? strdup(c) : NULL;
  r->n++;
}

/* ---- the project: DIR read only, OUT/work the engine's copy ---- */

static char s_dir[PATH_MAX], s_work[PATH_MAX], s_state[PATH_MAX], s_out[PATH_MAX];

static int run_argv(char *const argv[]) {
  pid_t p;
  int st;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
  int r = posix_spawn(&p, argv[0], &fa, NULL, argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  if (r) return -1;
  while (waitpid(p, &st, 0) < 0 && errno == EINTR) ;
  return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static int mkdirs_for(const char *path) {
  char d[PATH_MAX];
  snprintf(d, sizeof d, "%s", path);
  for (char *s = d + 1; (s = strchr(s, '/')); s++) { *s = 0; mkdir(d, 0755); *s = '/'; }
  return 0;
}

static int copy_file(const char *from, const char *to) {
  long n;
  char *b = slurp(from, &n);
  if (!b) return -1;
  mkdirs_for(to);
  spit(to, b, n);
  free(b);
  return 0;
}

/* .aux files (any depth), MAIN.bbl, MAIN.blg: what --state keeps */
static int state_file(const char *rel) {
  size_t n = strlen(rel);
  char bbl[PATH_MAX], blg[PATH_MAX];
  snprintf(bbl, sizeof bbl, "%s.bbl", job);
  snprintf(blg, sizeof blg, "%s.blg", job);
  return (n > 4 && !strcmp(rel + n - 4, ".aux")) || !strcmp(rel, bbl) || !strcmp(rel, blg);
}

static void walk(const char *root, const char *rel, void (*fn)(const char *root, const char *rel)) {
  char p[PATH_MAX];
  snprintf(p, sizeof p, "%s%s%s", root, *rel ? "/" : "", rel);
  DIR *d = opendir(p);
  if (!d) return;
  struct dirent *de;
  while ((de = readdir(d))) {
    if (de->d_name[0] == '.') continue;
    char r[PATH_MAX], full[PATH_MAX];
    snprintf(r, sizeof r, "%s%s%s", rel, *rel ? "/" : "", de->d_name);
    snprintf(full, sizeof full, "%s/%s", root, r);
    struct stat st;
    if (lstat(full, &st)) continue;
    if (S_ISDIR(st.st_mode)) walk(root, r, fn);
    else if (S_ISREG(st.st_mode)) fn(root, r);
  }
  closedir(d);
}

static int restored_bbl;  /* MAIN.bbl came from STATE: it is current for the .bib files STATE recorded, not today's */

static void restore_one(const char *root, const char *rel) {
  char to[PATH_MAX], from[PATH_MAX], bbl[PATH_MAX];
  if (!state_file(rel)) return;
  snprintf(to, sizeof to, "%s/%s", s_work, rel);
  if (access(to, F_OK) == 0) return;  /* the project has its own */
  snprintf(from, sizeof from, "%s/%s", root, rel);
  snprintf(bbl, sizeof bbl, "%s.bbl", job);
  if (copy_file(from, to) == 0 && !strcmp(rel, bbl)) restored_bbl = 1;
}

/* STATE/rule: latexmk's rule's memory beside the files, so a reopened session knows what the kept .bbl was made
   from (C3). One line: `bib <hash>`, bib_done_hash as of the save. */
static int load_rule(uint64_t *bib) {
  char p[PATH_MAX];
  long n = 0;
  snprintf(p, sizeof p, "%s/rule", s_state);
  char *b = slurp(p, &n);
  unsigned long long h;
  int ok = b && sscanf(b, "bib %llx", &h) == 1;
  if (ok) *bib = h;
  free(b);
  return ok;
}

static void save_one(const char *root, const char *rel) {
  char to[PATH_MAX], from[PATH_MAX];
  if (!state_file(rel)) return;
  snprintf(from, sizeof from, "%s/%s", root, rel);
  snprintf(to, sizeof to, "%s/%s", s_state, rel);
  copy_file(from, to);
}

static int make_work(void) {
  char src[PATH_MAX + 2];
  snprintf(src, sizeof src, "%s/", s_dir);
  char *cp_clone[] = {"/bin/cp", "-c", "-R", src, s_work, NULL};
  char *cp_plain[] = {"/bin/cp", "-R", src, s_work, NULL};
  if (run_argv(cp_clone) != 0 && run_argv(cp_plain) != 0) return -1;
  if (*s_state) walk(s_state, "", restore_one);
  return 0;
}

/* ---- the texts the app holds ---- */

struct text { char *rel; char *buf; long len; int dirty; };  /* dirty: changed, not yet on OUT/work (held) */
static struct text *texts;  /* grows: an Overleaf project can have more than 512 files the app holds (C12) */
static int ntexts, ctexts;

static struct text *text_of(const char *rel, int load) {
  for (int i = 0; i < ntexts; i++) if (!strcmp(texts[i].rel, rel)) return &texts[i];
  if (!load) return NULL;
  if (ntexts == ctexts) { ctexts = ctexts ? ctexts * 2 : 64; texts = realloc(texts, ctexts * sizeof *texts); if (!texts) die("realloc"); }
  struct text *t = &texts[ntexts++];
  char p[PATH_MAX];
  snprintf(p, sizeof p, "%s/%s", s_work, rel);
  t->rel = strdup(rel);
  t->buf = slurp(p, &t->len);
  t->dirty = 0;
  if (!t->buf) { t->buf = calloc(1, 1); t->len = 0; }
  return t;
}

static int safe_rel(const char *rel) {
  return *rel && rel[0] != '/' && !strstr(rel, "..");
}

/* ---- the serve loop ---- */

/* compile state */
static int c_seq = 0, c_run = 0, c_runs = 0, c_applied = 0, c_bibtex = 0;
static int c_idle = 1;            /* no run in progress: the compile settled (or none yet) */
static int cur_runseq = 0;        /* the internal seq (ctl) of the run in progress */
static int c_from_page = 0;
static uint64_t c_t_first;        /* reading the first command of this compile */
static long applied = 0;          /* open/change commands read so far */
static char last_final[PATH_MAX];
static char c_why[16] = "open";

/* Finishing while edits keep come (protocol rule 6 vs 3). An edit kills the run in flight, so a held key (an edit
   every 33 ms, a run ~100 ms to its PDF) would never let one finish. Edits are held instead (in memory: OUT/work and
   the engine see them only when applied) while the run in flight is the quickest way to show the oldest edit not yet
   shown: when restarting now would show it later than serve_period_ms after it came. They are applied as soon as that
   run announces a PDF or ends, or after hold_cap_us. Typing slower than a run never holds. */
static uint64_t t_pend0;          /* the oldest edit not yet applied (0: none) */
static uint64_t t_unshown;        /* the oldest edit not in an announced PDF (0: none) */
static uint64_t c_t_start;        /* the compile in progress was started (applied) */
static int c_pdfs;                /* PDFs announced by the compile in progress */
static uint64_t est_us = 100000;  /* a compile's start to its first PDF, smoothed */
static uint64_t hold_since;       /* holding since (0: not) */
static long holds_total;          /* for tests: bursts held */

static int para_on = 1;           /* the paragraph preview (para.c); TAUDOT_PARA=0 turns it off */
static uint64_t p_cmd_t;          /* when the commands being applied were read */
static int held_sigs;             /* below: finish (1) and goal (2) signals held for the runner */
#include "para.c"

static void ev_run(void) {
  fprintf(evout, "{\"ev\":\"run\",\"seq\":%d,\"run\":%d,\"applied\":%d,\"why\":\"%s\",\"from_page\":%d}\n", c_seq,
          c_run, c_applied, c_why, c_from_page);
  fflush(evout);
}

static void ev_pdf(const char *name, int pages, int final, uint64_t t_written, uint64_t finish_us) {
  char pdf[PATH_MAX], stx[PATH_MAX], log[PATH_MAX], stem[PATH_MAX];
  snprintf(stem, sizeof stem, "%s/%.*s", s_out, (int)(strlen(name) - 4), name);
  snprintf(pdf, sizeof pdf, "%s.pdf", stem);
  snprintf(log, sizeof log, "%s.log", stem);
  snprintf(stx, sizeof stx, "%s.synctex", stem);
  if (access(stx, F_OK)) snprintf(stx, sizeof stx, "%s.synctex.gz", stem);
  fprintf(evout, "{\"ev\":\"pdf\",\"seq\":%d,\"run\":%d,\"applied\":%d,\"pages\":%d,\"final\":%s,\"from_page\":%d,\"path\":",
          c_seq, c_run, c_applied, pages, final ? "true" : "false", c_from_page);
  jstr(evout, pdf);
  if (access(stx, F_OK) == 0) { fputs(",\"synctex\":", evout); jstr(evout, stx); }
  if (access(log, F_OK) == 0) { fputs(",\"log\":", evout); jstr(evout, log); }
  fprintf(evout, ",\"edit_us\":%llu,\"finish_us\":%llu}\n",
          (unsigned long long)(t_written > c_t_first ? t_written - c_t_first : 0), (unsigned long long)finish_us);
  fflush(evout);
  ring_add(&ring_pdf, pdf, access(stx, F_OK) == 0 ? stx : NULL, access(log, F_OK) == 0 ? log : NULL);
  if (final) snprintf(last_final, sizeof last_final, "%s", pdf);
  para_shown(pdf, pages);
  uint64_t t = now_us();
  if (!c_pdfs++ && c_t_start && t > c_t_start && !strcmp(c_why, "edit")) est_us = (3 * est_us + (t - c_t_start)) / 4;
  t_unshown = t_pend0;  /* everything applied is in it */
}

static void ev_bibtex(void) {
  char from[PATH_MAX], blg[PATH_MAX];
  snprintf(from, sizeof from, "%s/%s.blg", s_work, job);
  snprintf(blg, sizeof blg, "%s/%s-%d.blg", s_out, job, c_seq);
  int have = step_bib_ran && copy_file(from, blg) == 0;  /* makeindex alone leaves BibTeX's old .blg (C14) */
  fprintf(evout, "{\"ev\":\"bibtex\",\"seq\":%d,\"code\":%d,\"tool\":", c_seq, step_bibtex_code);
  jstr(evout, step_tool);
  if (have) { fputs(",\"blg\":", evout); jstr(evout, blg); }
  fprintf(evout, ",\"bbl_changed\":%s}\n", step_bbl_changed ? "true" : "false");
  fflush(evout);
  if (have) ring_add(&ring_blg, blg, NULL, NULL);
  if (have) c_bibtex = 1;
  if (tool_timed_out) ev_error("bibtex", "BibTeX (or biber, makeindex) timed out and was stopped");
}

static void save_state(void);

static char last_log[PATH_MAX];  /* the last run's log (written whether or not it made a PDF) */

/* A run ended: its final PDF if it wrote one (a fatal error before the first page writes none: P1), and its log. */
static void ev_final(void) {
  char name[64], pdf[PATH_MAX];
  snprintf(name, sizeof name, "final-%d.pdf", Eseq);
  snprintf(pdf, sizeof pdf, "%s/%s", s_out, name);
  snprintf(last_log, sizeof last_log, "%s/final-%d.log", s_out, Eseq);
  if (access(pdf, F_OK) == 0) { ev_pdf(name, Epages, 1, tE, 0); return; }
  last_final[0] = 0;
  ring_add(&ring_pdf, NULL, NULL, last_log);
}

static void ev_done(void) {
  fprintf(evout, "{\"ev\":\"done\",\"seq\":%d,\"runs\":%d,\"pages\":%d,\"code\":%d", c_seq, c_runs, Epages, Ecode);
  if (*last_final) { fputs(",\"path\":", evout); jstr(evout, last_final); }
  if (*last_log && access(last_log, F_OK) == 0) { fputs(",\"log\":", evout); jstr(evout, last_log); }
  if (c_bibtex) {
    char blg[PATH_MAX];
    snprintf(blg, sizeof blg, "%s/%s-%d.blg", s_out, job, c_seq);
    if (access(blg, F_OK) == 0) { fputs(",\"blg\":", evout); jstr(evout, blg); }
  }
  fputs("}\n", evout);
  fflush(evout);
  save_state();  /* after the event: the pane doesn't wait for it */
}

/* The rule after a run ended; starts the next run or settles. */
static void after_run(void) {
  para_rerun();
  int next = rule_step(cur_runseq, c_runs);
  if (step_bibtex_ran) ev_bibtex();
  if (next < 0) {
    c_idle = 1;
    ev_done();
    return;
  }
  cur_runseq = next;
  c_run++;
  c_runs++;
  snprintf(c_why, sizeof c_why, "%s", step_bbl_rerun ? "bibtex" : "aux");
  c_from_page = snaps[step_j].pages;
  ev_run();
}

/* A compile starts with every edit read so far (edit_us counts from the oldest of them). */
static void compile_started(void) {
  c_t_start = now_us();
  c_t_first = t_pend0 ? t_pend0 : c_t_start;
  c_pdfs = 0;
}

/* A new compile from snapshot j for a change at byte k of rel. */
static void start_compile(int j, const char *rel, long k, const char *why) {
  c_seq++;
  c_run = 1;
  c_runs = 1;
  c_bibtex = 0;
  c_applied = (int)applied;
  compile_started();
  snprintf(c_why, sizeof c_why, "%s", why);
  cur_runseq = ++runseq;
  if (para_on) para_compile(cur_runseq, rel, k);
  rollback(j, cur_runseq, rel, k);
  drop_after(j);
  want_seq = cur_runseq;
  c_from_page = snaps[j].pages;
  c_idle = 0;
  ev_run();
}

/* Has any run read rel (the last finished one, or any snapshot)? */
static int was_read(const char *rel) {
  if (fin_read(rel)) return 1;
  for (int s = 0; s < nsnaps; s++) if (ext_of(&snaps[s], rel) > 0) return 1;
  return 0;
}

/* A .bib (or other file only BibTeX reads) changed: latexmk's rule from the last run. */
static void bib_changed(void) {
  if (!c_idle) return;  /* the running compile's rule step will see it */
  c_seq++;
  c_run = 0;
  c_runs = 1;
  c_bibtex = 0;
  c_applied = (int)applied;
  compile_started();
  snprintf(c_why, sizeof c_why, "rescan");
  para_rerun();
  int next = rule_step(cur_runseq, 1);
  if (step_bibtex_ran) ev_bibtex();
  if (next < 0) { ev_done(); return; }
  cur_runseq = next;
  c_run = 1;
  snprintf(c_why, sizeof c_why, "bibtex");
  c_from_page = snaps[step_j].pages;
  c_idle = 0;
  ev_run();
}

/* changes gathered from one burst of commands */
struct pend { char rel[PATH_MAX]; long k; };
static struct pend *pend;  /* grows: a burst can change any number of files (C12) */
static int npend, cpend;

static void note_change(const char *rel, long k) {
  for (int i = 0; i < npend; i++)
    if (!strcmp(pend[i].rel, rel)) { if (k < pend[i].k) pend[i].k = k; return; }
  if (npend == cpend) { cpend = cpend ? cpend * 2 : 64; pend = realloc(pend, cpend * sizeof *pend); if (!pend) die("realloc"); }
  snprintf(pend[npend].rel, PATH_MAX, "%s", rel);
  pend[npend].k = k;
  npend++;
}

static void write_text(struct text *t) {
  char p[PATH_MAX];
  snprintf(p, sizeof p, "%s/%s", s_work, t->rel);
  mkdirs_for(p);
  spit(p, t->buf, t->len);
}

static void cmd_open(const char *rel, const char *buf, long len) {
  struct text *t = text_of(rel, 1);
  if (!t) return;
  long k = first_diff(t->buf, t->len, buf, len);
  if (k == t->len && k == len) return;  /* the same */
  free(t->buf);
  t->buf = malloc(len + 1);
  memcpy(t->buf, buf, len);
  t->buf[len] = 0;
  t->len = len;
  t->dirty = 1;
  note_change(rel, k);
  if (para_on) para_edit(rel, k, p_cmd_t);
}

static int cmd_change(const char *rel, long pos, long del, const char *ins, long nins) {
  struct text *t = text_of(rel, 1);
  if (!t || pos < 0 || del < 0 || pos + del > t->len) return -1;
  long nlen = t->len - del + nins;
  char *nb = malloc(nlen + 1);
  memcpy(nb, t->buf, pos);
  memcpy(nb + pos, ins, nins);
  memcpy(nb + pos + nins, t->buf + pos + del, t->len - pos - del);
  nb[nlen] = 0;
  free(t->buf);
  t->buf = nb;
  t->len = nlen;
  t->dirty = 1;
  note_change(rel, pos);
  if (para_on) para_edit(rel, pos, p_cmd_t);
  return 0;
}

/* Rescan: files in DIR the app doesn't hold as text, against the engine's copy. */
static int skip_rescan(const char *rel) {
  static const char *ext[] = {".aux", ".bbl", ".blg", ".toc", ".lof", ".lot", ".out", ".log", ".fls", ".synctex",
                              ".synctex.gz", ".fdb_latexmk", ".nav", ".snm", ".bcf", ".run.xml", ".idx", ".ind", ".ilg",
                              NULL};
  size_t n = strlen(rel);
  for (int i = 0; ext[i]; i++) {
    size_t e = strlen(ext[i]);
    if (n > e && !strcmp(rel + n - e, ext[i])) return 1;
  }
  char pdf[PATH_MAX];
  snprintf(pdf, sizeof pdf, "%s.pdf", job);
  return !strcmp(rel, pdf) || text_of(rel, 0) != NULL;
}

static int rescan_bib;
static void rescan_one(const char *root, const char *rel) {
  if (skip_rescan(rel)) return;
  char from[PATH_MAX], to[PATH_MAX];
  snprintf(from, sizeof from, "%s/%s", root, rel);
  snprintf(to, sizeof to, "%s/%s", s_work, rel);
  long ln = 0, lo = 0;
  char *nw = slurp(from, &ln), *old = slurp(to, &lo);
  if (nw && (!old || ln != lo || memcmp(nw, old, ln))) {
    long k = first_diff(old, lo, nw, ln);
    mkdirs_for(to);
    spit(to, nw, ln);
    size_t n = strlen(rel);
    if ((n > 4 && !strcmp(rel + n - 4, ".bib")) || (n > 4 && !strcmp(rel + n - 4, ".bst"))) rescan_bib = 1;
    else note_change(rel, k);
  }
  free(nw); free(old);
}

/* `finish` (1: SIGUSR1) and `goal` (2: SIGUSR2) for the runner. Held while there is none we can signal: before the
   first snapshot its handlers may not exist, and while resuming `runner` is the snapshot, for which SIGUSR1 means
   "wake" (patch 0010). A new runner reads the goal from ctl itself; a held finish is for the run in progress. */
static int held_sigs;
static void send_held_sigs(void) {
  if (!held_sigs) return;
  if (c_idle) { held_sigs = 0; return; }  /* nothing running: nothing to finish, the next run reads ctl */
  if (!runner || resuming || nsnaps == 0) return;
  if (held_sigs & 1) sig_runner(SIGUSR1);
  if (held_sigs & 2) sig_runner(SIGUSR2);
  held_sigs = 0;
}

/* A finished PDF (P) or its late SyncTeX (Y) for a run that isn't the current one: a finisher outlives the runner
   an edit killed. Nobody will be told of it, so nothing would ever remove it (C17): remove it now. */
static void drop_unannounced(const char *m) {
  int pid, seq;
  char name[128];
  if (m[0] == 'P') {
    unsigned long long t;
    int pages;
    if (sscanf(m, "P %d %d %d %llu %llu %llu %llu %127s", &pid, &seq, &pages, &t, &t, &t, &t, name) != 8) return;
  } else {
    unsigned long long t;
    if (sscanf(m, "Y %d %d %llu %127s", &pid, &seq, &t, name) != 4) return;
    if (seq == cur_runseq && !c_idle) return;  /* the current run's: beside an announced PDF */
  }
  if (strncmp(name, "pdf-", 4) || strchr(name, '/')) return;
  char stem[PATH_MAX], p[PATH_MAX];
  if (m[0] == 'Y') {  /* its own file only, and not if its PDF was announced (before this run began): kept with it */
    size_t sn = strcspn(name, ".");
    for (int i = 0; i < KEEP; i++) {
      const char *a = ring_pdf.paths[i][0], *b = a ? strrchr(a, '/') : NULL;
      if (b && !strncmp(b + 1, name, sn) && b[1 + sn] == '.') return;
    }
    snprintf(p, sizeof p, "%s/%s", s_out, name);
    unlink(p);
    return;
  }
  snprintf(stem, sizeof stem, "%s/%s", s_out, name);
  char *dot = strstr(stem + strlen(s_out) + 1, ".");
  if (dot) *dot = 0;
  static const char *ext[] = {".pdf", ".log", ".synctex", ".synctex.gz"};
  for (int i = 0; i < 4; i++) { snprintf(p, sizeof p, "%s%s", stem, ext[i]); unlink(p); }
}

/* ---- the engine process tree ---- */

static const char *s_engine, *s_fmt, *s_snap_ms, *s_main;

/* Fork the engine for run `cur_runseq` (ctl says so), from the top of the document, on a new socket. */
static void start_engine(void) {
  int sv[2];
  if (sock >= 0) close(sock);
  if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv)) die("socketpair");
  int big = 1 << 20;
  for (int k = 0; k < 2; k++) {
    setsockopt(sv[k], SOL_SOCKET, SO_SNDBUF, &big, sizeof big);
    setsockopt(sv[k], SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
  }
  sock = sv[0];
  ctl_seq = cur_runseq; ctl_k = -1; snprintf(ctl_rel, sizeof ctl_rel, "-");
  write_ctl();
  pid_t pid = fork();
  if (pid < 0) die("fork");
  if (pid == 0) {
    char fdbuf[16], log[PATH_MAX], fmtarg[256], sarg[32];
    snprintf(fdbuf, sizeof fdbuf, "%d", sv[1]);
    close(sv[0]);
    setenv("TAUDOT_LIVE_FD", fdbuf, 1);
    setenv("TAUDOT_PROJECT", s_work, 1);
    setenv("TAUDOT_LIVE_OUT", s_out, 1);
    setenv("TAUDOT_SNAPSHOT_MS", s_snap_ms, 1);
    if (chdir(s_work)) _exit(127);
    snprintf(log, sizeof log, "%s/engine.out", s_out);
    int fd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
    int nul = open("/dev/null", O_RDONLY);
    if (nul >= 0) { dup2(nul, 0); close(nul); }
    snprintf(fmtarg, sizeof fmtarg, "-fmt=%s", s_fmt);
    snprintf(sarg, sizeof sarg, "-synctex=%s", synctex);
    execl(s_engine, s_engine, fmtarg, "-interaction=batchmode", sarg, s_main, (char *)NULL);
    _exit(127);
  }
  close(sv[1]);
  engine_root = runner = pid;
  root_start = runner_start = proc_start(pid);
  resuming = 0;
  gotP = gotE = gotR = gotT = 0;
  ships = 0;
}

/* The engine's root exited: every engine process is gone or orphaned (a run crashed: its snapshots exit in a
   cascade, each reporting X). The compile settles with no PDF, and the engine starts again with the next command
   (on the same text it would likely crash again) (C5). */
static int engine_dead;
static void forget_engine(void) {
  para_forget();
  killall_engine();
  engine_root = runner = 0;
  for (int s = 0; s < nsnaps; s++) {
    for (int k = 0; k < snaps[s].n; k++) free(snaps[s].e[k].rel);
    free(snaps[s].e);
  }
  nsnaps = 0;
  for (int k = 0; k < nfin; k++) free(fin[k].rel);
  nfin = 0;
  resuming = 0;
  held_sigs = 0;
  while (waitpid(-1, NULL, WNOHANG) > 0) ;
}

static void engine_died(void) {
  ev_error("engine", "the engine exited");
  forget_engine();
  engine_dead = 1;
  if (!c_idle) {
    c_idle = 1;
    last_final[0] = 0;
    last_log[0] = 0;
    Ecode = 3;
    ev_done();
  }
}

/* A new compile on a new engine: the work copy already has every change. */
static void restart_engine(const char *why) {
  engine_dead = 0;
  npend = 0;
  c_seq++;
  c_run = 1;
  c_runs = 1;
  c_bibtex = 0;
  c_applied = (int)applied;
  compile_started();
  snprintf(c_why, sizeof c_why, "%s", why);
  cur_runseq = ++runseq;
  want_seq = cur_runseq;
  c_from_page = 0;
  c_idle = 0;
  para_forget();
  para_rerun();
  start_engine();
  ev_run();
}

/* After a burst: roll back for the files the engine read, or run the BibTeX rule for .bib files. */
static void flush_texts(void) {
  for (int i = 0; i < ntexts; i++) if (texts[i].dirty) { write_text(&texts[i]); texts[i].dirty = 0; }
}

static void apply_pending(int bib, const char *why) {
  int j = -1; long kk = 0; const char *rr = NULL;
  flush_texts();
  hold_since = 0;
  if (engine_dead) { restart_engine(why); t_pend0 = 0; return; }
  if (nsnaps == 0) {  /* no snapshot to roll back to (C13): hold until the run takes one or ends, then from the top */
    if (!c_idle) return;
    forget_engine();
    restart_engine(why);
    t_pend0 = 0;
    return;
  }
  for (int i = 0; i < npend; i++) {
    const char *rel = pend[i].rel;
    size_t n = strlen(rel);
    if (n > 4 && (!strcmp(rel + n - 4, ".bib") || !strcmp(rel + n - 4, ".bst"))) { bib = 1; continue; }
    if (c_idle && !was_read(rel)) continue;  /* nothing has read it: nothing to redo */
    int js = snap_before(rel, pend[i].k);
    if (js >= 0 && (j < 0 || js < j)) { j = js; kk = pend[i].k; rr = rel; }
  }
  npend = 0;
  if (j >= 0) start_compile(j, rr, kk, why);
  else if (bib) bib_changed();
  t_pend0 = 0;
}

/* Hold the pending edits (see t_pend0)? */
static uint64_t hold_cap_us(void) { return est_us * 3 > 300000 ? est_us * 3 : 300000; }
static int holding(uint64_t t) {
  if (!npend || c_idle || engine_dead || nsnaps == 0 || c_pdfs || !t_unshown) return 0;
  if (t - t_unshown + est_us <= (uint64_t)serve_period_ms * 1000) return 0;  /* a restart still shows it in time */
  if (!hold_since) { hold_since = t; holds_total++; }
  return t - hold_since < hold_cap_us();
}

/* fetch events, from the store client's log (TEXSTORE_LOG) */
static char s_fetchlog[PATH_MAX];
static long fetch_off = 0, fetch_files = 0, fetch_bytes = 0;
static uint64_t fetch_last_ev = 0;
static void poll_fetch(void) {
  uint64_t t = now_us();
  if (t - fetch_last_ev < 100000) return;
  FILE *f = fopen(s_fetchlog, "r");
  if (!f) return;
  fseek(f, fetch_off, SEEK_SET);
  char line[PATH_MAX + 64], last[PATH_MAX] = "";
  int waiting = 0, any = 0, failed = 0;
  const char *root = getenv("TEXSTORE_ROOT");
  while (fgets(line, sizeof line, f)) {
    size_t n = strlen(line);
    if (!n || line[n - 1] != '\n') break;  /* half a line: next time */
    fetch_off += (long)n;
    line[n - 1] = 0;
    char *kind = strchr(line, '\t'), *what;
    if (!kind) continue;
    kind++;
    what = strchr(kind, '\t');
    if (!what) continue;
    *what++ = 0;
    if (!strcmp(kind, "store") || !strcmp(kind, "prefetch") || !strcmp(kind, "fallback")) {
      if (!strncmp(what, "manifest ", 9) || !strcmp(what, "index")) continue;
      fetch_files++;
      struct stat st;
      char p[PATH_MAX];
      snprintf(p, sizeof p, "%s/%s", root ? root : "", what);
      if (root && stat(p, &st) == 0) fetch_bytes += st.st_size;
      snprintf(last, sizeof last, "%s", what);
      waiting = strcmp(kind, "prefetch") != 0;
      any = 1;
    } else if (!strcmp(kind, "fail")) {
      failed = 1;
      snprintf(last, sizeof last, "%s", what);
    }
  }
  fclose(f);
  if (any) {
    const char *shown = !strncmp(last, "texmf-dist/", 11) ? last + 11 : last;
    fputs("{\"ev\":\"fetch\",\"file\":", evout); jstr(evout, shown);
    fprintf(evout, ",\"files\":%ld,\"bytes\":%ld,\"waiting\":%s}\n", fetch_files, fetch_bytes, waiting ? "true" : "false");
    fflush(evout);
    fetch_last_ev = t;
  }
  if (failed) {
    char msg[PATH_MAX + 64];
    snprintf(msg, sizeof msg, "can't fetch %s", last);
    ev_error("offline", msg);
  }
}

/* At exit and whenever a compile settles (a killed driver keeps the last settled state, C3). */
static void save_state(void) {
  if (!*s_state) return;
  mkdir(s_state, 0755);
  walk(s_work, "", save_one);
  char p[PATH_MAX], line[64];
  snprintf(p, sizeof p, "%s/rule", s_state);
  int n = snprintf(line, sizeof line, "bib %llx\n", (unsigned long long)bib_done_hash);
  spit(p, line, n);
}

/* The engine's root exiting wakes the loop (a byte on this pipe), so at rest it can sleep: nothing else needs a
   timer while no compile runs (idle wakeups, clients/mac/Tests/perf/README.md). */
static int chld_pipe[2] = {-1, -1};
static void on_chld(int sig) {
  (void)sig;
  int e = errno;
  if (chld_pipe[1] >= 0) (void)!write(chld_pipe[1], "c", 1);
  errno = e;
}

/* poll's timeout: 50 ms while a compile runs (fetch progress), until the hold's end while holding, else none. */
static int loop_timeout(void) {
  if (hold_since) {
    uint64_t t = now_us(), end = hold_since + hold_cap_us();
    int ms = t >= end ? 0 : (int)((end - t + 999) / 1000);
    return ms < 50 ? ms : 50;
  }
  return c_idle && !npend && !held_sigs ? -1 : 50;
}

static int serve_main(int argc, char **argv) {
  const char *engine = getenv("TAUDOT_PDFTEX"), *fmt = "pdflatex", *snap_ms = "20", *state = NULL;
  synctex = "-1";
  snap_cap_from_env();
  int i = 1;
  for (; i < argc && argv[i][0] == '-' && argv[i][1] == '-'; i++) {
    if (!strcmp(argv[i], "--serve")) ;
    else if (!strcmp(argv[i], "--engine") && i + 1 < argc) engine = argv[++i];
    else if (!strcmp(argv[i], "--fmt") && i + 1 < argc) fmt = argv[++i];
    else if (!strcmp(argv[i], "--snapshot-ms") && i + 1 < argc) snap_ms = argv[++i];
    else if (!strcmp(argv[i], "--bibtex") && i + 1 < argc) bibtex = argv[++i];
    else if (!strcmp(argv[i], "--synctex") && i + 1 < argc) synctex = argv[++i];
    else if (!strcmp(argv[i], "--biber") && i + 1 < argc) biber = argv[++i];
    else if (!strcmp(argv[i], "--makeindex") && i + 1 < argc) makeindex = argv[++i];
    else if (!strcmp(argv[i], "--makeglossaries") && i + 1 < argc) makeglossaries = argv[++i];
    else if (!strcmp(argv[i], "--max-runs") && i + 1 < argc) max_runs = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--state") && i + 1 < argc) state = argv[++i];
    else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
  }
  if (argc - i != 3 || !engine) {
    fprintf(stderr, "usage: %s --serve [--engine PATH] [--fmt NAME] [--snapshot-ms N] [--bibtex PATH] [--biber PATH] [--makeindex PATH] "
                    "[--makeglossaries SCRIPT] [--max-runs N] "
                    "[--synctex N] [--state STATE] DIR MAIN.tex OUT\n", argv[0]);
    return 2;
  }
  serve = 1;
  evout = stdout;
  if (getenv("TAUDOT_PARA") && !strcmp(getenv("TAUDOT_PARA"), "0")) para_on = 0;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);  /* edits in, previews out: a keystroke's path */
  signal(SIGPIPE, SIG_IGN);
  if (pipe(chld_pipe) == 0) {
    for (int k = 0; k < 2; k++) {
      fcntl(chld_pipe[k], F_SETFL, O_NONBLOCK);
      fcntl(chld_pipe[k], F_SETFD, FD_CLOEXEC);
    }
    struct sigaction sa = {0};
    sa.sa_handler = on_chld;
    sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGCHLD, &sa, NULL);
  }
  mkdir(argv[i + 2], 0755);
  if (!realpath(argv[i], s_dir) || !realpath(argv[i + 2], s_out)) die("realpath");
  if (state) { mkdir(state, 0755); if (!realpath(state, s_state)) s_state[0] = 0; }
  const char *main_tex = argv[i + 1];
  snprintf(s_work, sizeof s_work, "%s/work", s_out);
  outdir = s_out;
  snprintf(job, sizeof job, "%s", main_tex);
  if (strlen(job) > 4 && !strcmp(job + strlen(job) - 4, ".tex")) job[strlen(job) - 4] = 0;
  { /* OUT/work from DIR; a stale one from an earlier session is replaced */
    char old[PATH_MAX];
    snprintf(old, sizeof old, "%s/work.old.%d", s_out, (int)getpid());
    rename(s_work, old);
    char *rm[] = {"/bin/rm", "-rf", old, NULL};
    if (access(old, F_OK) == 0) run_argv(rm);
  }
  if (make_work()) { ev_error("engine", "can't copy the project"); return 1; }
  snprintf(g_dir, sizeof g_dir, "%s", s_work);
  snprintf(ctl, sizeof ctl, "%s/ctl", s_out);
  snprintf(s_fetchlog, sizeof s_fetchlog, "%s/fetch.log", s_out);
  unlink(s_fetchlog);
  setenv("TEXSTORE_LOG", s_fetchlog, 1);
  ctl_seq = 0; ctl_k = -1; snprintf(ctl_rel, sizeof ctl_rel, "-");
  write_ctl();
  {
    char *bl = bib_state();
    bib_done_hash = bib_sources_hash(bl);
    free(bl);
    /* a .bbl from STATE was made from the .bib files as they were then; with no record of them, rerun BibTeX */
    if (restored_bbl && !load_rule(&bib_done_hash)) bib_done_hash = 0;

    char bcfp[PATH_MAX];
    long n = 0;
    snprintf(bcfp, sizeof bcfp, "%s/%s.bcf", g_dir, job);
    char *bcf = slurp(bcfp, &n);
    bcf_done_hash = bcf_sources_hash(bcf);
    free(bcf);
    idx_init();
  }

  /* hello */
  {
    char cmdline[PATH_MAX + 32], banner[256] = "";
    snprintf(cmdline, sizeof cmdline, "'%s' --version 2>/dev/null", engine);
    FILE *v = popen(cmdline, "r");
    if (v) {
      if (fgets(banner, sizeof banner, v)) banner[strcspn(banner, "\n")] = 0;
      pclose(v);
    }
    fputs("{\"ev\":\"hello\",\"protocol\":1,\"engine\":", evout); jstr(evout, banner);
    fputs(",\"image\":", evout); jstr(evout, getenv("TEXSTORE_IMAGE") ? getenv("TEXSTORE_IMAGE") : "");
    fputs("}\n", evout);
    fflush(evout);
  }

  s_engine = engine; s_fmt = fmt; s_snap_ms = snap_ms; s_main = main_tex;
  c_t_first = now_us();
  c_seq = 1; c_run = 1; c_runs = 1; c_idle = 0; cur_runseq = 0; want_seq = 0;
  snprintf(c_why, sizeof c_why, "open");
  start_engine();
  ev_run();

  /* the loop: stdin (commands), the engine's socket (messages), the fetch log */
  size_t icap = 1 << 20, ilen = 0;  /* grows: one command can be a whole file (C2) */
  char *ibuf = malloc(icap);
  static char mbuf[1 << 16];
  int stdin_open = 1;
  int nP_seen = 0;
  while (stdin_open) {
    struct pollfd pf[3] = {{.fd = 0, .events = POLLIN}, {.fd = sock, .events = POLLIN}, {.fd = chld_pipe[0], .events = POLLIN}};
    int r = poll(pf, chld_pipe[0] >= 0 ? 3 : 2, chld_pipe[0] >= 0 ? loop_timeout() : 50);
    if (r < 0 && errno != EINTR) break;
    if (r > 0 && (pf[2].revents & POLLIN)) { char b[64]; while (read(chld_pipe[0], b, sizeof b) > 0) ; }
    poll_fetch();
    if (engine_root && waitpid(engine_root, NULL, WNOHANG) == engine_root) engine_died();
    /* engine messages first: they can end a run */
    if (r > 0 && (pf[1].revents & POLLIN)) {
      for (;;) {
        ssize_t n = recv(sock, mbuf, sizeof mbuf - 1, MSG_DONTWAIT);
        if (n <= 0) break;
        mbuf[n] = 0;
        if (para_handle(mbuf)) continue;
        int hadE = gotE;
        handle(mbuf);
        if (mbuf[0] == 'P' && gotP && lastP.seq == cur_runseq && !c_idle) {
          ev_pdf(lastP.name, lastP.pages, 0, lastP.t3, lastP.t2 - lastP.t1);
          nP_seen++;
        } else if (mbuf[0] == 'P' || mbuf[0] == 'Y') {
          drop_unannounced(mbuf);
        }
        if (mbuf[0] == 'E' && gotE && !hadE && Eseq == cur_runseq && !c_idle) {
          ev_final();
          after_run();
        }
        if (mbuf[0] == 'X') ev_error("engine", "an engine process died");
        /* An edit's run shipped its first page (the snapshot was taken just before the edit, so that's the edited
           page, mostly): finish one now, as well as at the goal page. The goal is the last page in view; waiting for
           it cost a page of typesetting (PaperA, edit on page 1 of 2 in view: 73 vs 103 ms). A finish asked for before
           the runner is past the edit waits for it (patch 0009). */
        if (mbuf[0] == 'p' && ships == 1 && !c_idle && !c_pdfs && !strcmp(c_why, "edit") && c_run == 1 &&
            (serve_goal < 0 || serve_goal > c_from_page))
          held_sigs |= 1;
      }
    }
    if (npend && (nsnaps > 0 || c_idle) && !holding(now_us())) apply_pending(0, "edit");  /* held until the first snapshot or the run's end */
    send_held_sigs();
    if (r > 0 && (pf[0].revents & (POLLIN | POLLHUP))) {
      if (icap - 1 - ilen < (1 << 16)) { icap *= 2; ibuf = realloc(ibuf, icap); if (!ibuf) die("realloc"); }
      ssize_t n = read(0, ibuf + ilen, icap - 1 - ilen);
      if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
      if (n <= 0) { stdin_open = 0; break; }
      ilen += (size_t)n;
      ibuf[ilen] = 0;
      char *line = ibuf, *nl;
      int rescan = 0;
      uint64_t t_cmd = now_us();
      p_cmd_t = t_cmd;
      int had_edit = 0;
      long applied0 = applied;
      while ((nl = memchr(line, '\n', ibuf + ilen - line))) {
        *nl = 0;
        struct cmd c;
        if (*line && parse_cmd(line, &c) == 0) {
          const char *name = c.a[0].s;
          if (!strcmp(name, "open") && c.argc == 3 && c.a[1].is_str && c.a[2].is_str && safe_rel(c.a[1].s)) {
            had_edit = 1;
            applied++;
            cmd_open(c.a[1].s, c.a[2].s, c.a[2].len);
          } else if (!strcmp(name, "change") && c.argc == 5 && c.a[1].is_str && !c.a[2].is_str && !c.a[3].is_str &&
                     c.a[4].is_str && safe_rel(c.a[1].s)) {
            had_edit = 1;
            applied++;
            if (cmd_change(c.a[1].s, c.a[2].n, c.a[3].n, c.a[4].s, c.a[4].len))
              ev_error("protocol", "change outside the file");
          } else if (!strcmp(name, "goal") && c.argc == 2 && !c.a[1].is_str) {
            serve_goal = (int)c.a[1].n;
            write_ctl();
            held_sigs |= 2;
          } else if (!strcmp(name, "finish") && c.argc == 1) {
            held_sigs |= 1;
          } else if (!strcmp(name, "rescan") && c.argc == 1) {
            rescan = 1;
          } else ev_error("protocol", line);
          free_cmd(&c);
        } else if (*line) ev_error("protocol", line);
        line = nl + 1;
      }
      ilen = (size_t)(ibuf + ilen - line);
      memmove(ibuf, line, ilen);
      if ((had_edit || rescan) && !t_pend0) t_pend0 = t_cmd;  /* edit_us counts from the oldest command not applied */
      if (applied > applied0 && !t_unshown) t_unshown = t_cmd;
      if (rescan) { rescan_bib = 0; walk(s_dir, "", rescan_one); }
      if (rescan_bib || (npend && !holding(t_cmd))) {
        apply_pending(rescan_bib, rescan && !had_edit ? "rescan" : "edit");
        rescan_bib = 0;
      }
      if (!npend) t_pend0 = 0;  /* a rescan that found nothing */
    }
    send_held_sigs();
  }
  (void) nP_seen;
  save_state();
  killall_engine();
  while (waitpid(-1, NULL, WNOHANG) > 0) ;
  return 0;
}
