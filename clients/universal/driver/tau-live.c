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
  size_t len;
} text;

static char dir[2048], work[2048], tdir[2048], outdir[2048], lib[2048], mainf[1024];
static char **eng_argv;
static int msg_r = -1, msg_w = -1, life_r = -1, life_w = -1;
static long snapshot_ms = 20;  // as pdftex-live --serve
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


static void emit(const char *fmt, ...) {
  va_list a;
  va_start(a, fmt);
  vfprintf(stdout, fmt, a);
  va_end(a);
  fputc('\n', stdout);
  fflush(stdout);
}

static text *get_text(const char *rel) {
  for (int i = 0; i < ntexts; i++)
    if (!strcmp(texts[i].rel, rel)) return &texts[i];
  texts = realloc(texts, (ntexts + 1) * sizeof *texts);
  text *t = &texts[ntexts++];
  t->rel = strdup(rel);
  t->data = NULL;
  t->len = 0;
  char p[4096];
  snprintf(p, sizeof p, "%s/%s", work, rel);
  FILE *f = fopen(p, "rb");
  if (f) {
    fseek(f, 0, SEEK_END);
    t->len = ftell(f);
    fseek(f, 0, SEEK_SET);
    t->data = malloc(t->len + 1);
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
  kill_fins();
  if (runner > 0) kill(runner, SIGKILL);
  for (int i = 0; i < nsnaps; i++) { kill(snaps[i].pid, SIGKILL); free_snap(&snaps[i]); }
  nsnaps = 0;
  runner = -1;
}

static void spawn_engine(void) {
  kill_all();
  char e1[4200], e2[4200], e3[64], e4[64], e5[64], e6[4200], e7[4200];
  snprintf(e1, sizeof e1, "TAU_PROJECT=%s", work);
  snprintf(e2, sizeof e2, "TAU_OUT=%s", tdir);
  snprintf(e3, sizeof e3, "TAU_FD=%d", msg_w);
  snprintf(e4, sizeof e4, "TAU_LIFE=%d", life_r);
  snprintf(e5, sizeof e5, "TAU_SNAPSHOT_MS=%ld", snapshot_ms);
  snprintf(e6, sizeof e6, "DYLD_INSERT_LIBRARIES=%s", lib);
  snprintf(e7, sizeof e7, "TAU_ZCACHE=%s/zcache", outdir);
  int n = 0;
  while (environ[n]) n++;
  char **env = calloc(n + 16, sizeof *env);
  int k = 0;
  for (int i = 0; i < n; i++)
    if (strncmp(environ[i], "TAU_PROJECT=", 12) && strncmp(environ[i], "TAU_OUT=", 8) &&
        strncmp(environ[i], "TAU_FD=", 7) && strncmp(environ[i], "TAU_LIFE=", 9) &&
        strncmp(environ[i], "TAU_SNAPSHOT_MS=", 16) && strncmp(environ[i], "TAU_ZCACHE=", 11))
      env[k++] = environ[i];
  env[k++] = e1, env[k++] = e2, env[k++] = e3, env[k++] = e4, env[k++] = e5, env[k++] = e6, env[k++] = e7;
  if (finish_every) env[k++] = "TAU_FINISH=every";
  env[k] = NULL;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  char logp[4096];
  snprintf(logp, sizeof logp, "%s/engine.out", tdir);
  posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&fa, 1, logp, O_WRONLY | O_CREAT | O_APPEND, 0644);
  posix_spawn_file_actions_adddup2(&fa, 1, 2);
  posix_spawn_file_actions_addchdir(&fa, work);
  if (posix_spawn(&root, eng_argv[0], &fa, NULL, eng_argv, env)) die("spawn engine");
  posix_spawn_file_actions_destroy(&fa);
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
// The pass in flight: what it typesets, for its event
static struct { int seq; char rel[512]; long end; int line; } pass;
// The reader (tau-tdl serve): one process, requests in order, one answer line each
static pid_t reader = -1;
static int reader_in = -1, reader_out = -1;
static char tdl_bin[2048];
typedef struct { char *head; int seq; int64_t t_sent; int pdf; } reader_job;
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
static void apply_run(change *ch, int nch, const char *why, int rerun);
static void apply(change *ch, int nch, const char *why) { apply_run(ch, nch, why, 0); }
static void apply_run(change *ch, int nch, const char *why, int rerun) {
  if (rerun) run_no++;
  else { seq++; run_no = 1; blg_this[0] = 0; }
  drop_deferred();
  if (!rerun) applied_at_run = applied;
  t_apply = now_us();
  kill_fins();
  int best = -1;
  for (int i = nsnaps - 1; i >= 0 && best < 0; i--) {
    int ok = 1;
    for (int c = 0; c < nch && ok; c++)
      if (snap_extent(&snaps[i], ch[c].rel) > ch[c].k) ok = 0;
    if (ok) best = i;
  }
  if (best < 0) {
    spawn_engine();
    emit("{\"ev\":\"run\",\"seq\":%d,\"run\":%d,\"applied\":%d,\"why\":\"%s\",\"from_page\":0,\"fresh\":true}", seq,
         run_no, applied_at_run, why);
    return;
  }
  if (runner > 0) kill(runner, SIGKILL);
  runner = -1;
  long next_ext = best + 1 < nsnaps && nch ? snap_extent(&snaps[best + 1], ch[0].rel) : -1;
  for (int i = best + 1; i < nsnaps; i++) { kill(snaps[i].pid, SIGKILL); free_snap(&snaps[i]); }
  nsnaps = best + 1;
  snap *s = &snaps[best];
  char p[4096];
  // (a pass from far back would typeset pages before the paragraph: slower than the exact page, and not the
  // paragraph's own lines if a float or page break comes between; the next key resumes at the edited line)
  if (para && hook && !rerun && nch == 1 && s->cur && !strcmp(s->cur, ch[0].rel) && s->cur_pos <= ch[0].k &&
      ch[0].k - s->cur_pos < 4096 && s->pages > 0) {  // (before the first page: font map, title page)
    text *t = get_text(ch[0].rel);
    pid_t warm = s->warm;
    if (warm > 0) snprintf(p, sizeof p, "%s/ctl-warm-%d", tdir, warm);
    else snprintf(p, sizeof p, "%s/ctl-para-%d", tdir, s->pid);
    FILE *f = fopen(p, "w");
    fprintf(f, "seq %d\nfile %s\nend %ld\n", seq, ch[0].rel, para_end(t, ch[0].k));
    pass.seq = seq;
    snprintf(pass.rel, sizeof pass.rel, "%s", ch[0].rel);
    pass.end = para_end(t, ch[0].k);
    pass.line = 1;
    for (long i = 0; i < pass.end && (size_t)i < t->len; i++) pass.line += t->data[i] == '\n';
    // LaTeX's own output routine still handles its float penalties (below -10000); a page break ships at natural
    // height through LaTeX's \shipout (its hooks define what the page's \write nodes expand to; no headers)
    // at the pass's own break (\taudotpg defined: the paragraph is over) only its last \prevgraf lines are shipped,
    // taken off with \lastbox, through the primitive \shipout; if anything but lines, glue and penalties is in the
    // way (a footnote's insert, a mark, a whatsit) the page so far ships instead, as at a break inside the paragraph
    fprintf(f, "prefix \\gdef\\taudotg{}\\gdef\\taudotown{0}\\gdef\\taudotn{0}\\toks255=\\expandafter{\\the\\output}\\output={\\taudotout}%%\n");
    fprintf(f, "flush \\taudotflush%%\n");
    {  // the paragraph's new text from the resume point, so the pass needn't reread the file
      long E = para_end(t, ch[0].k), P = s->cur_pos;
      if (P >= 0 && E >= P && E - P < 32768) {
        fprintf(f, "text %ld %ld\n--\n", P, E - P);
        fwrite(t->data + P, 1, E - P, f);
      }
    }
    fclose(f);
    if (warm > 0) {  // the warm pass starts now; the snapshot parks a new one when this one exits
      char fifo[4200];
      snprintf(fifo, sizeof fifo, "%s/fifo-%d", tdir, warm);
      int ff = open(fifo, O_WRONLY | O_NONBLOCK);
      if (ff >= 0) { write(ff, "g", 1); close(ff); }  // (TAU_WARM_PIPE)
      else kill(warm, SIGUSR1);
      if (dbg) fprintf(dbg, "%lld signalled warm %d\n", (long long)now_us(), warm), fflush(dbg);
      s->warm = 0;
    }
  }
  snprintf(p, sizeof p, "%s/ctl-%d", tdir, s->pid);
  FILE *f = fopen(p, "w");
  fprintf(f, "seq %d\n", seq);
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
  fclose(f);
  kill(s->pid, SIGUSR1);
  if (dbg) {
    fprintf(dbg, "%lld apply seq %d -> snapshot %d (%d of %d) edit %s@%ld snapshot extent %ld; next %ld\n",
            (long long)now_us(), seq, s->pid, best, nsnaps, ch[0].rel, ch[0].k, snap_extent(s, ch[0].rel),
            next_ext);
    fflush(dbg);
  }
  run_open = 1;
  emit("{\"ev\":\"run\",\"seq\":%d,\"run\":%d,\"applied\":%d,\"why\":\"%s\",\"from_page\":%d,\"snapshot\":%d,"
       "\"snapshots\":%d}",
       seq, run_no, applied_at_run, why, from_page, s->pid, nsnaps);
}

static void set_text(const char *rel, char *data, size_t len, const char *why) {
  text *t = get_text(rel);
  size_t k = 0;
  size_t m = t->len < len ? t->len : len;
  while (k < m && t->data[k] == data[k]) k++;
  if (k == m && t->len == len) { free(data); return; }
  free(t->data);
  t->data = data;
  t->len = len;
  char p[4096];
  snprintf(p, sizeof p, "%s/%s", work, rel);
  write_file(p, data, len);
  change c = {(char *)rel, (long)k};
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
  fprintf(stdout, "{\"ev\":\"pdf\",\"seq\":%d,\"run\":%d,\"applied\":%d,\"pages\":%d,\"final\":%s,\"from_page\":%d,"
          "\"path\":", s, run_no, applied_at_run, pages, final ? "true" : "false", from_page);
  jstr(stdout, pdf, strlen(pdf));
  if (exists(sx)) { fputs(",\"synctex\":", stdout); jstr(stdout, sx, strlen(sx)); }
  if (exists(lg)) { fputs(",\"log\":", stdout); jstr(stdout, lg, strlen(lg)); }
  fprintf(stdout, ",\"edit_us\":%lld,\"finish_us\":%lld}\n", (long long)(t - t_apply),
          (long long)(!final && fs ? t - fs : 0));
  fflush(stdout);
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
    int has_bibdata = strstr(lines, "\\bibdata{") != NULL;
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
    fprintf(stdout, "{\"ev\":\"bibtex\",\"seq\":%d,\"code\":%d,\"tool\":\"%s\"", seq, code, tools);
    if (ran_bib) { fputs(",\"blg\":", stdout); jstr(stdout, blg_this, strlen(blg_this)); }
    fprintf(stdout, ",\"bbl_changed\":%s}\n", bbl_changed ? "true" : "false");
    fflush(stdout);
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
    fprintf(stdout, "{\"ev\":\"error\",\"what\":\"format\",\"message\":");
    jstr(stdout, msg, strlen(msg));
    fputs("}\n", stdout);
    fflush(stdout);
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
  fprintf(stdout, "{\"ev\":\"done\",\"seq\":%d,\"runs\":%d,\"pages\":%d,\"code\":%d", seq, run_no, pages, code);
  if (exists(pdf)) { fputs(",\"path\":", stdout); jstr(stdout, pdf, strlen(pdf)); }
  if (exists(lg)) { fputs(",\"log\":", stdout); jstr(stdout, lg, strlen(lg)); }
  if (blg_this[0]) { fputs(",\"blg\":", stdout); jstr(stdout, blg_this, strlen(blg_this)); }
  fprintf(stdout, ",\"edit_us\":%lld,\"fresh_runs\":%d}\n", (long long)(t - t_apply), fresh_runs);
  fflush(stdout);
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

static void para_none(int s, const char *why, int lines, int pieces, const char *bin) {
  fprintf(stdout, "{\"ev\":\"para\",\"go\":%d,\"seq\":%d,\"applied\":%d,\"file\":", s, s, applied_at_run);
  jstr(stdout, pass.rel, strlen(pass.rel));
  fprintf(stdout, ",\"state\":\"none\",\"why\":\"%s\",\"lines\":%d,\"pieces\":%d", why, lines, pieces);
  if (bin && *bin) { fputs(",\"bin\":", stdout); jstr(stdout, bin, strlen(bin)); }
  fprintf(stdout, ",\"us\":%lld}\n", (long long)(now_us() - t_apply));
  fflush(stdout);
}

static const double SP_BP = 72.0 / 72.27 / 65536.0;

static void para_lines(const char *line, int s, int lines, int pieces, const char *bin, int64_t t_q) {
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
  if (!own) return para_none(s, "insert", lines, pieces, bin);  // in a box: a float, a caption, a minipage
  if (pieces > 1) return para_none(s, "split", lines, pieces, bin);  // the new lines cross a page or column
  if (!geo || lines <= 0) return para_none(s, lines <= 0 ? "end" : "insert", lines, pieces, bin);  // (insert, mark)
  // the old lines: the newest output whose SyncTeX has them (the paragraph's \par line in that output's text)
  sx_index *x = NULL;
  sx_para o = {0};
  out_rec *src = NULL;
  for (int k = 0; k < 8 && k < nouts && !src; k++) {
    int slot = (nouts - 1 - k) % 8;
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
  if (!src) return para_none(s, "noanchor", lines, pieces, bin);
  if (o.found == -1) return para_none(s, "split", lines, pieces, bin);
  if (o.found == -2) return para_none(s, "segment", lines, pieces, bin);
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
}

// An answer from the reader: the oldest request's event goes out
static void reader_answer(const char *l) {
  if (!njobs) return;
  reader_job j = jobs[0];
  memmove(jobs, jobs + 1, --njobs * sizeof *jobs);
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
    fprintf(stdout, "{\"ev\":\"error\",\"what\":\"offline\",\"message\":");
    jstr(stdout, m, strlen(m));
    fputs(",\"file\":", stdout);
    jstr(stdout, line + 10, strlen(line + 10));
    fputs("}\n", stdout);
    fflush(stdout);
    return;
  }
  if (line[0] == 'G' && line[1] == ' ') {
    nfetch++;
    fprintf(stdout, "{\"ev\":\"fetch\",\"file\":");
    jstr(stdout, line + 2, strlen(line + 2));
    fprintf(stdout, ",\"files\":%d,\"bytes\":0,\"waiting\":true}\n", nfetch);
    fflush(stdout);
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
  if (sscanf(line, "F %d %d %d %lld", &a, &b, &c, &t) == 4) {
    if (b == seq && nfins < 256) fins[nfins++] = a;
    t_fin_start[a & 0xffff] = t;
    return;
  }
  int code = 0;
  if (sscanf(line, "E %d %d %d %lld %63s %d", &a, &b, &c, &t, tag, &code) >= 5) {
    if (b != seq) return;
    if (!strcmp(tag, "run") && a != runner) { defer(line); return; }
    if (!strcmp(tag, "run")) {
      run_open = 0;
      emit_pdf("run", b, a, c, 1, t);
      rule_step(a, c, t, code);
    } else if (!strcmp(tag, "fin")) {
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
    char *d = malloc(len + 1);
    memcpy(d, t->data, pos);
    memcpy(d + pos, v[4].s, v[4].n);
    memcpy(d + pos + v[4].n, t->data + pos + del, t->len - pos - del);
    set_text(v[1].s, d, len, "edit");
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
    emit("{\"ev\":\"error\",\"what\":\"protocol\",\"message\":\"unknown command\"}");
  }
  for (int i = 0; i < n; i++) free(v[i].s);
}

// ---------------------------------------------------------------------------------------------------- main

int main(int argc, char **argv) {
  int i = 1;
  snprintf(lib, sizeof lib, "%s", argv[0]);
  char *sl = strrchr(lib, '/');
  if (sl) snprintf(sl + 1, lib + sizeof lib - sl - 1, "libtau.dylib");
  else snprintf(lib, sizeof lib, "libtau.dylib");
  snprintf(tdl_bin, sizeof tdl_bin, "%.*stau-tdl", sl ? (int)(sl + 1 - lib) : 0, lib);  // (beside tau-live)
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
    else if (!strcmp(argv[i], "--dense") && i + 1 < argc) dense = atol(argv[++i]);
    else { fprintf(stderr, "tau-live: unknown option %s\n", argv[i]); return 2; }
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
        "\\if T\\taudotok\\xdef\\taudotg{-g\\number\\dimexpr\\voffset+\\skip0+\\dimen2\\relax x"
        "\\number\\dimexpr\\ht2+\\dp2-\\skip0\\relax x\\number\\dimen2}\\fi}\\taudotmark{2}\\taudotx"
        "\\if T\\taudotok\\csname tex_shipout:D\\endcsname\\vbox{\\moveright\\dimen0\\box2}\\taudotmark{3}"
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
    static char inj[24576];
    snprintf(inj, sizeof inj,
             "\\def\\taudotsig#1{%s}\\AddToHook{shipout/after}{\\taudotsig{ship/\\the\\ReadonlyShipoutCounter}}"
             "%s%s%s\\csname @@input\\endcsname %s", sig, pass_macros, pad,
             getenv("TAU_PHASES") ? "\\def\\taudotmark#1{\\taudotsig{t/#1}}" : "\\def\\taudotmark#1{}", a[n - 1]);
    a[n - 1] = inj;
    eng_argv = a;
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
  restore_state();
  if (hook && para) reader_start();  // (the paragraph preview's reader, ready before the first pass)
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
    struct pollfd pf[3] = {{0, POLLIN, 0}, {msg_r, POLLIN, 0}, {reader_out, POLLIN, 0}};
    if (poll(pf, reader_out >= 0 ? 3 : 2, 200) < 0 && errno != EINTR) die("poll");
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
  keep_state();
  close(life_w);
  return 0;
}
