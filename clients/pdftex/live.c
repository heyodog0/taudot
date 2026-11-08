/* live.c: driver for the live pdfTeX prototype. Runs a document, applies scripted edits, and times the PDF
   after each one.

   Copyright 2026 Ryan Truong. GPL-2.0-or-later (it drives a GPL engine and lives with its patches).

   pdftex-live [--engine PATH] [--fmt NAME] [--snapshot-ms N] [--finish-all] [--leave] [--bibtex PATH] [--biber PATH]
               [--makeindex PATH] [--makeglossaries SCRIPT] [--max-runs N] [--synctex N] DIR MAIN.tex EDITS OUT

   DIR is a copy of the project; edits are written into it. EDITS has one edit per line:
     label <TAB> file <TAB> search <TAB> replacement        (\t \n \\ escapes; # starts a comment)
   The first occurrence of `search` in `file` is replaced. OUT receives the engine's PDFs and a ctl file.

   After every run (the first, and each edit's), latexmk's rule: the project files the run wrote (OUT/w-<seq>/) that
   differ from the disk are written to DIR; BibTeX runs when the \citation/\bibdata/\bibstyle lines of the main .aux
   or of an .aux it \@inputs (\include) changed, when a \bibdata .bib changed since the last BibTeX run, or when
   there's \bibdata and no .bbl; and if a changed file was read by the run, or the log says
   "No file <it>.", the engine reruns, rolled back to the latest snapshot before the first changed byte. At most
   --max-runs runs (5, latexmk's max_repeat) per compile. An edit to a file the engine never read (a .bib) is
   written to DIR and goes straight to the rule above: BibTeX, then a rerun only if the .bbl changed.
   Results go to stdout as TSV. See clients/pdftex/README.md for the engine's messages. */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000u + ts.tv_nsec / 1000;
}

static void die(const char *m) { perror(m); exit(1); }

/* ---- engine state as the driver sees it ---- */

#define MAXSNAP 4096
#define MAXEXT 512
struct ext { char *rel; long n; };
/* childless: the snapshot's child was retired (thinned out, below), so a rollback to it wakes it with SIGUSR1
   instead of by killing its child. Kept entries next to each other: entry i+1's parent is entry i unless entry i is
   childless (then entry i+1's parent is gone). */
struct snap { int pid; uint64_t t; int n; struct ext *e; int pages; int childless; uint64_t start; };
static struct snap snaps[MAXSNAP];
static int nsnaps = 0;
static int snap_cap = 256;  /* TAUDOT_MAX_SNAPSHOTS: more and the table is thinned (C4) */
static int engine_retire;   /* the engine said `V 1 retire` (patch 0010): it survives thinning. An older one would
                               take a retired child as a crash and exit, so its table isn't thinned */
static int runner = 0;      /* current runner pid; while resuming, the snapshot that will fork it */
static uint64_t runner_start, root_start;  /* their start times (proc_start), as for each snapshot */
static int resuming = 0;    /* a snapshot was woken and its new runner hasn't sent R: `runner` is that snapshot, whose
                               new child we can't signal yet (C1). Every R ends it. */
static int engine_root = 0;
static int sock = -1;
static const char *outdir;

/* events of the current wait */
struct pmsg { int pid, seq, pages; uint64_t t0, t1, t2, t3; char name[128]; };
static struct pmsg lastP;
static int gotP, gotE, gotR, Eseq, Epages, Ecode, Rseq;
static uint64_t tE, tR, tfirst_page;
static int ships;
static int finish_all = 0;
static int leave = 0;     /* --leave: exit without killing the engine, as a crashed driver would */
static struct pmsg allP[4096];
static int nallP = 0;
static struct ext fin[MAXEXT];   /* T: the finished run's extents */
static int fin_opened[MAXEXT];
static int nfin, gotT;

/* A process's start time (µs since the epoch), 0 if it's gone. Engine processes die without the driver hearing of
   it (a crashed run's snapshots exit in a cascade); their pids can be reused, so every signal checks the start time
   recorded when the pid was learned (C5). */
static uint64_t proc_start(int pid) {
  struct proc_bsdinfo bi;
  if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != (int)sizeof bi) return 0;
  return (uint64_t)bi.pbi_start_tvsec * 1000000u + bi.pbi_start_tvusec;
}

static void sig(int pid, uint64_t start, int signo) {
  if (pid > 0 && start && proc_start(pid) == start) kill(pid, signo);
}
static void sig_runner(int signo) { sig(runner, runner_start, signo); }

static long ext_of(struct snap *s, const char *rel) {
  for (int i = 0; i < s->n; i++)
    if (strcmp(s->e[i].rel, rel) == 0) return s->e[i].n;
  return 0;
}

static int known_pid(int pid) {
  if (pid == runner) return 1;
  for (int i = 0; i < nsnaps; i++) if (snaps[i].pid == pid) return 1;
  return 0;
}

/* Every snapshot is a live process: past snap_cap, retire every other one between the first (the engine root) and
   the last (the runner's parent), so a long run keeps at most snap_cap processes and rolls back a little further. A
   retired snapshot gets SIGTERM; its parent (the entry before it) then waits childless for a wake (patch 0010). */
static void thin(void) {
  int w = 1;
  for (int r = 1; r < nsnaps; r++) {
    if (r % 2 == 1 && r < nsnaps - 1) {
      snaps[w - 1].childless = 1;
      sig(snaps[r].pid, snaps[r].start, SIGTERM);
      for (int k = 0; k < snaps[r].n; k++) free(snaps[r].e[k].rel);
      free(snaps[r].e);
      continue;
    }
    snaps[w++] = snaps[r];
  }
  nsnaps = w;
}

static void handle(char *m) {
  int a, b, c, d;
  unsigned long long t;
  if (m[0] == 'S') {
    int n;
    int pages = 0;
    if (sscanf(m, "S %d %d %llu %d %d", &a, &b, &t, &n, &pages) < 4) return;
    if (!known_pid(a)) return;  /* from a lineage we killed */
    if (nsnaps == MAXSNAP || (engine_retire && nsnaps >= snap_cap)) {
      if (!engine_retire) { fprintf(stderr, "too many snapshots\n"); exit(1); }
      thin();
    }
    struct snap *s = &snaps[nsnaps++];
    s->pid = a; s->t = t; s->n = 0; s->e = calloc(n ? n : 1, sizeof *s->e); s->pages = pages; s->childless = 0;
    s->start = a == runner ? runner_start : proc_start(a);
    char *p = strchr(m, '\n');
    while (p && *++p && s->n < n) {
      long x; char rel[PATH_MAX];
      if (sscanf(p, "%ld %1023[^\n]", &x, rel) != 2) break;
      s->e[s->n].rel = strdup(rel); s->e[s->n].n = x; s->n++;
      p = strchr(p, '\n');
    }
    runner = b;
    runner_start = proc_start(b);
  } else if (m[0] == 'R') {
    if (sscanf(m, "R %d %d %d %llu", &a, &b, &c, &t) != 4) return;
    if (!known_pid(a)) return;
    runner = b; gotR = 1; Rseq = c; tR = t;
    runner_start = proc_start(b);
    resuming = 0;
  } else if (m[0] == 'p') {
    if (sscanf(m, "p %d %d %llu", &a, &b, &t) != 3) return;
    if (a != runner) return;
    if (!ships) tfirst_page = t;
    ships++;
  } else if (m[0] == 'P') {
    struct pmsg p;
    unsigned long long t0, t1, t2, t3;
    if (sscanf(m, "P %d %d %d %llu %llu %llu %llu %127s", &p.pid, &p.seq, &p.pages, &t0, &t1, &t2, &t3, p.name) != 8)
      return;
    p.t0 = t0; p.t1 = t1; p.t2 = t2; p.t3 = t3;
    lastP = p; gotP = 1;
    if (finish_all && nallP < 4096) allP[nallP++] = p;
  } else if (m[0] == 'E') {
    if (sscanf(m, "E %d %d %d %d %llu", &a, &b, &c, &d, &t) != 5) return;
    if (a != runner) return;
    gotE = 1; Eseq = b; Epages = c; Ecode = d; tE = t;
  } else if (m[0] == 'T') {
    int n;
    if (sscanf(m, "T %d %d %d", &a, &b, &n) != 3) return;
    if (a != runner) return;
    for (int k = 0; k < nfin; k++) free(fin[k].rel);
    nfin = 0;
    char *p = strchr(m, '\n');
    while (p && *++p && nfin < n && nfin < MAXEXT) {
      long x; int o; char rel[PATH_MAX];
      if (sscanf(p, "%ld %d %1023[^\n]", &x, &o, rel) != 3) break;
      fin[nfin].rel = strdup(rel); fin[nfin].n = x; fin_opened[nfin] = o; nfin++;
      p = strchr(p, '\n');
    }
    gotT = 1;
  } else if (m[0] == 'V') {
    if (strstr(m, " retire")) engine_retire = 1;
  } else if (m[0] == 'X') {
    fprintf(stderr, "engine: %s", m);
  }
}

/* Read messages until cond() or timeout. */
static int pump(int (*cond)(void), int timeout_ms) {
  static char buf[1 << 16];
  uint64_t end = now_us() + (uint64_t)timeout_ms * 1000;
  while (!cond()) {
    int64_t left = (int64_t)(end - now_us()) / 1000;
    if (left <= 0) return 0;
    struct pollfd pf = {.fd = sock, .events = POLLIN};
    int r = poll(&pf, 1, (int)left);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) continue;
    ssize_t n = recv(sock, buf, sizeof buf - 1, 0);
    if (n <= 0) continue;
    buf[n] = 0;
    handle(buf);
  }
  return 1;
}

static int want_seq;
static int c_E(void) { return gotE && Eseq == want_seq; }
static int c_PE(void) { return gotE && Eseq == want_seq && gotP && lastP.seq == want_seq; }

/* the latest snapshot that read no byte at or after k of rel */
static int snap_before(const char *rel, long k) {
  for (int s = nsnaps - 1; s >= 0; s--)
    if (ext_of(&snaps[s], rel) <= k) return s;
  return -1;
}

static char ctl[PATH_MAX];
static int serve = 0, serve_goal = -1, serve_period_ms = 150;  /* --serve: the finish rule's fields in ctl */
static int ctl_seq = 0; static long ctl_k = -1; static char ctl_rel[PATH_MAX] = "-";
/* --serve's paragraph preview (para.c): a window [pwin, the edit] for paragraph snapshots, and the one it has */
static long ctl_pwin = -1, ctl_phave = -1;

static void write_ctl(void) {
  char tmp[PATH_MAX];
  snprintf(tmp, sizeof tmp, "%s.tmp", ctl);
  FILE *cf = fopen(tmp, "w");
  if (!cf) die(tmp);
  if (serve) fprintf(cf, "%d %ld %s %d %d %ld %ld\n", ctl_seq, ctl_k, ctl_rel, serve_goal, serve_period_ms, ctl_pwin, ctl_phave);
  else fprintf(cf, "%d %ld %s\n", ctl_seq, ctl_k, ctl_rel);
  fclose(cf);
  rename(tmp, ctl);
}

/* Start run `seq` from snapshot j, for a change at byte k of rel (the runner finishes a PDF once past it). */
static void rollback(int j, int seq, const char *rel, long k) {
  (void) j;
  ctl_seq = seq; ctl_k = k;
  snprintf(ctl_rel, sizeof ctl_rel, "%s", rel && *rel ? rel : "-");
  write_ctl();
}

static int c_resumed(void) { return !resuming; }

static void drop_after(int j) {
  /* A snapshot woken by the last rollback hasn't named its new runner yet: wait for its R, so the kills below hit
     that runner and never the snapshot itself (at j = 0 the engine root, C1). */
  if (resuming && !pump(c_resumed, 5000)) {
    fprintf(stderr, "no R from snapshot %d\n", runner);
    resuming = 0;
    for (int s = 0; s <= j && s < nsnaps; s++) if (snaps[s].pid == runner) runner = 0;  /* never kill a kept one */
  }
  /* stop the runner, then kill from the oldest dropped snapshot down, so only snapshot j wakes */
  if (runner) sig_runner(SIGSTOP);
  for (int s = j + 1; s < nsnaps; s++) sig(snaps[s].pid, snaps[s].start, SIGKILL);
  if (runner) sig_runner(SIGKILL);
  for (int s = j + 1; s < nsnaps; s++) free(snaps[s].e);
  nsnaps = j + 1;
  runner = snaps[j].pid;  /* it forks the new runner and reports R */
  runner_start = snaps[j].start;
  if (snaps[j].childless) { sig_runner(SIGUSR1); snaps[j].childless = 0; }  /* nothing above woke it */
  resuming = 1;
  gotP = gotE = gotR = gotT = 0;
  ships = 0;
}

/* ---- files ---- */

static char *slurp(const char *path, long *len) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *b = malloc(n + 1);
  if (fread(b, 1, n, f) != (size_t)n) { fclose(f); free(b); return NULL; }
  fclose(f);
  b[n] = 0;
  *len = n;
  return b;
}

static void spit(const char *path, const char *buf, long len) {
  char tmp[PATH_MAX];
  snprintf(tmp, sizeof tmp, "%s.taudot-tmp", path);
  FILE *f = fopen(tmp, "wb");
  if (!f || fwrite(buf, 1, len, f) != (size_t)len || fclose(f)) die(tmp);
  if (rename(tmp, path)) die("rename");
}

static void unescape(char *s) {
  char *d = s;
  for (; *s; s++) {
    if (*s == '\\' && s[1]) {
      s++;
      *d++ = *s == 'n' ? '\n' : *s == 't' ? '\t' : *s;
    } else *d++ = *s;
  }
  *d = 0;
}

/* ---- memory ---- */

static void memory(const char *when) {
  /* every engine process: the snapshots, the runner */
  uint64_t foot = 0, rss = 0;
  int n = 0;
  int pids[MAXSNAP + 1];
  for (int i = 0; i < nsnaps; i++) pids[n++] = snaps[i].pid;
  if (runner) pids[n++] = runner;
  int counted = 0;
  for (int i = 0; i < n; i++) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0) {
      foot += ri.ri_phys_footprint;
      rss += ri.ri_resident_size;
      counted++;
    }
  }
  printf("memory\t%s\tprocesses=%d\tfootprint_sum_mb=%.1f\trss_sum_mb=%.1f\n", when, counted, foot / 1048576.0,
         rss / 1048576.0);
}

/* ---- latexmk's rule ---- */

static const char *bibtex = NULL;
static const char *synctex = NULL;
static const char *biber = NULL;    /* --biber PATH: biblatex's backend (the year's TeX Live binary) */
static const char *makeindex = NULL, *makeglossaries = NULL;  /* --makeindex PATH, --makeglossaries SCRIPT */  /* --synctex N: pass -synctex=N to the engine (Overleaf: 1) */
static int max_runs = 5;
static char g_dir[PATH_MAX], job[PATH_MAX];
static int runseq = 0;          /* every engine run, edits and reruns: ctl seq, final-<seq>.pdf */

/* the bib-relevant lines of an .aux, concatenated (latexmk's trigger for BibTeX) */
static char *bib_lines(const char *aux) {
  size_t cap = 1024, n = 0;
  char *o = malloc(cap);
  o[0] = 0;
  if (!aux) return o;
  for (const char *p = aux; *p;) {
    const char *e = strchr(p, '\n');
    size_t l = e ? (size_t)(e - p + 1) : strlen(p);
    if (!strncmp(p, "\\citation{", 10) || !strncmp(p, "\\bibdata{", 9) || !strncmp(p, "\\bibstyle{", 10)) {
      if (n + l + 1 > cap) { cap = (n + l + 1) * 2; o = realloc(o, cap); }
      memcpy(o + n, p, l); n += l; o[n] = 0;
    }
    p += l;
  }
  return o;
}

/* The bib lines of the main .aux on disk and of every .aux it \@inputs (an \include'd chapter's), as BibTeX reads
   them. */
static char *bib_state(void) {
  char *todo[64], *all = calloc(1, 1);
  size_t n = 0;
  int nt = 0, done = 0;
  char first[PATH_MAX];
  snprintf(first, sizeof first, "%s.aux", job);
  todo[nt++] = strdup(first);
  while (done < nt) {
    char path[PATH_MAX];
    long len = 0;
    snprintf(path, sizeof path, "%s/%s", g_dir, todo[done]);
    char *aux = slurp(path, &len);
    free(todo[done++]);
    if (!aux) continue;
    char *bl = bib_lines(aux);
    size_t l = strlen(bl);
    all = realloc(all, n + l + 1);
    memcpy(all + n, bl, l + 1);
    n += l;
    free(bl);
    for (char *q = strstr(aux, "\\@input{"); q && nt < 64; q = strstr(q + 1, "\\@input{")) {
      char *e = strchr(q + 8, '}');
      if (e && e - (q + 8) < PATH_MAX - 1) todo[nt++] = strndup(q + 8, e - (q + 8));
    }
    free(aux);
  }
  while (done < nt) free(todo[done++]);
  return all;
}

/* A hash of the \bibdata .bib files' contents (FNV-1a), to see whether one changed since the last BibTeX run. */
static uint64_t bib_sources_hash(const char *bl) {
  uint64_t h = 1469598103934665603ull;
  for (const char *p = strstr(bl, "\\bibdata{"); p; p = strstr(p + 1, "\\bibdata{")) {
    const char *q = p + 9;
    while (*q && *q != '}' && *q != '\n') {
      char name[PATH_MAX], path[PATH_MAX];
      size_t n = strcspn(q, ",}\n");
      if (n >= sizeof name - 5) n = sizeof name - 5;
      memcpy(name, q, n); name[n] = 0;
      snprintf(path, sizeof path, "%s/%s%s", g_dir, name, strstr(name, ".bib") ? "" : ".bib");
      long len = 0;
      char *b = slurp(path, &len);
      for (long i = 0; b && i < len; i++) h = (h ^ (unsigned char)b[i]) * 1099511628211ull;
      h = (h ^ (b ? 1 : 0)) * 1099511628211ull;
      free(b);
      q += n;
      if (*q == ',') q++;
    }
  }
  return h;
}
static uint64_t bib_done_hash;  /* the .bib files as of the last BibTeX run (or the start: the .bbl is current) */
static int last_seq;            /* the run whose outputs are on disk */

static long first_diff(const char *a, long la, const char *b, long lb) {
  long k = 0;
  if (!a) return 0;
  while (k < la && k < lb && a[k] == b[k]) k++;
  return k;
}

struct change { char rel[PATH_MAX]; long k; };
/* rule_step's changed files: as many as a run writes (C12: 70 chapter .aux files were cut at 64, never written back) */
static struct change *add_change(struct change **ch, int *n, int *cap, const char *rel, long k) {
  if (*n == *cap) { *cap = *cap ? *cap * 2 : 64; *ch = realloc(*ch, *cap * sizeof **ch); if (!*ch) die("realloc"); }
  struct change *c = &(*ch)[(*n)++];
  snprintf(c->rel, PATH_MAX, "%s", rel);
  c->k = k;
  return c;
}

static int fin_read(const char *rel) {
  for (int i = 0; i < nfin; i++)
    if (!strcmp(fin[i].rel, rel)) return fin_opened[i] && fin[i].n > 0;
  return 0;
}

/* latexmk's $bibtex_use = 1: run BibTeX only if a \bibdata file exists (arXiv sources often ship only the .bbl) */
static int bib_files_exist(const char *bl) {
  for (const char *p = strstr(bl, "\\bibdata{"); p; p = strstr(p + 1, "\\bibdata{")) {
    const char *q = p + 9;
    while (*q && *q != '}') {
      char name[PATH_MAX], path[PATH_MAX];
      size_t n = strcspn(q, ",}");
      if (n >= sizeof name - 5) n = sizeof name - 5;
      memcpy(name, q, n); name[n] = 0;
      snprintf(path, sizeof path, "%s/%s%s", g_dir, name, strstr(name, ".bib") ? "" : ".bib");
      if (access(path, R_OK) == 0) return 1;
      q += n;
      if (*q == ',') q++;
    }
  }
  return 0;
}

/* latexmk's programs (BibTeX, biber, makeindex, makeglossaries), run in the project with output to OUT/bibtex.out.
   Synchronous, so each is bounded (C6): TAUDOT_TOOL_TIMEOUT_S (120) and the program's whole process group is
   killed. It reads nothing (stdin is /dev/null, not the app's command pipe) and inherits no other descriptor (the
   engine's socket). With_path: PATH starts with makeindex's directory (makeglossaries calls it by name). Returns its
   exit code, or -1 (killed, timed out, couldn't start). */
static int tool_timed_out;
static int run_tool(char *const argv[], int with_path) {
  int timeout_s = getenv("TAUDOT_TOOL_TIMEOUT_S") ? atoi(getenv("TAUDOT_TOOL_TIMEOUT_S")) : 120;
  tool_timed_out = 0;
  fflush(stdout);
  pid_t p = fork();
  if (p < 0) return -1;
  if (p == 0) {
    char log[PATH_MAX];
    setpgid(0, 0);
    snprintf(log, sizeof log, "%s/bibtex.out", outdir);
    int fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
    int nul = open("/dev/null", O_RDONLY);
    if (nul >= 0) { dup2(nul, 0); close(nul); }
    for (int k = 3, max = getdtablesize() < 4096 ? getdtablesize() : 4096; k < max; k++) close(k);
    if (chdir(g_dir)) _exit(127);
    if (with_path && makeindex) {
      char dir[PATH_MAX], path[2 * PATH_MAX];
      snprintf(dir, sizeof dir, "%s", makeindex);
      char *sl = strrchr(dir, '/');
      if (sl) *sl = 0;
      snprintf(path, sizeof path, "%s:%s", dir, getenv("PATH") ? getenv("PATH") : "/usr/bin:/bin");
      setenv("PATH", path, 1);
    }
    execvp(argv[0], argv);
    _exit(127);
  }
  setpgid(p, p);  /* both sides, so the group exists before either goes on */
  uint64_t end = now_us() + (uint64_t)(timeout_s > 0 ? timeout_s : 120) * 1000000u;
  int st = 0;
  for (;;) {
    pid_t r = waitpid(p, &st, WNOHANG);
    if (r == p) break;
    if (r < 0 && errno != EINTR) return -1;
    if (now_us() > end) {
      fprintf(stderr, "%s timed out after %d s\n", argv[0], timeout_s);
      kill(-p, SIGKILL);
      while (waitpid(p, &st, 0) < 0 && errno == EINTR) ;
      tool_timed_out = 1;
      return -1;
    }
    usleep(2000);
  }
  kill(-p, SIGKILL);  /* anything it left running in its group */
  return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* biber: the .bbl from the .bcf (biblatex). Same as run_bibtex, another program. */
static int run_prog(const char *prog) {
  char *argv[] = {(char *)prog, job, NULL};
  return run_tool(argv, 0);
}

static int run_argv_in_project(char *const argv[]) { return run_tool(argv, 1); }

/* makeindex and glossaries: latexmk's rule for a generated input (Overleaf's latexmkrc adds the glossaries ones):
   run when the input file changed since the last run of its program, or there is no output. Hashes by file name. */
struct idxrec { char name[64]; uint64_t h; };
static struct idxrec idxrecs[32];
static int nidxrecs;
static uint64_t file_hash(const char *rel) {
  char p[PATH_MAX];
  long n = 0;
  snprintf(p, sizeof p, "%s/%s", g_dir, rel);
  char *b = slurp(p, &n);
  uint64_t h = 1469598103934665603ull;
  for (long i = 0; b && i < n; i++) h = (h ^ (unsigned char)b[i]) * 1099511628211ull;
  h = (h ^ (b ? 1 : 0)) * 1099511628211ull;
  free(b);
  return h;
}
static uint64_t *idx_done(const char *rel) {
  for (int i = 0; i < nidxrecs; i++) if (!strcmp(idxrecs[i].name, rel)) return &idxrecs[i].h;
  if (nidxrecs == 32) return NULL;
  snprintf(idxrecs[nidxrecs].name, sizeof idxrecs[nidxrecs].name, "%s", rel);
  idxrecs[nidxrecs].h = 0;
  return &idxrecs[nidxrecs++].h;
}
/* The (input, output) pairs: <job>.idx -> <job>.ind; each \@newglossary{type}{log}{out}{in} in the .aux. */
static int idx_rules(char in[][64], char out[][64], int *gloss, int max) {
  int n = 0;
  if (makeindex && n < max) {
    snprintf(in[n], 64, "%s.idx", job); snprintf(out[n], 64, "%s.ind", job); gloss[n] = 0; n++;
  }
  if (makeglossaries) {
    char p[PATH_MAX];
    long len = 0;
    snprintf(p, sizeof p, "%s/%s.aux", g_dir, job);
    char *aux = slurp(p, &len);
    for (char *q = aux ? strstr(aux, "\\@newglossary{") : NULL; q && n < max; q = strstr(q + 1, "\\@newglossary{")) {
      char f[4][32];
      if (sscanf(q, "\\@newglossary{%31[^}]}{%31[^}]}{%31[^}]}{%31[^}]}", f[0], f[1], f[2], f[3]) != 4) continue;
      snprintf(in[n], 64, "%s.%s", job, f[3]); snprintf(out[n], 64, "%s.%s", job, f[2]); gloss[n] = 1; n++;
    }
    free(aux);
  }
  return n;
}
/* At start: the outputs on disk are taken as current for their inputs. */
static void idx_init(void) {
  char in[16][64], out[16][64];
  int gloss[16], n = idx_rules(in, out, gloss, 16);
  for (int i = 0; i < n; i++) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/%s", g_dir, out[i]);
    uint64_t *d = idx_done(in[i]);
    if (d && access(p, F_OK) == 0) *d = file_hash(in[i]);
  }
}

/* A hash of the .bcf's bibtex datasources (<bcf:datasource ...>NAME</bcf:datasource>), as latexmk tracks them. */
static uint64_t bcf_sources_hash(const char *bcf) {
  uint64_t h = 1469598103934665603ull;
  for (const char *p = bcf ? strstr(bcf, "<bcf:datasource") : NULL; p; p = strstr(p + 1, "<bcf:datasource")) {
    const char *a = strchr(p, '>'), *b = a ? strstr(a, "</bcf:datasource>") : NULL;
    if (!a || !b || b - a - 1 >= PATH_MAX - 1) continue;
    char name[PATH_MAX], path[PATH_MAX];
    memcpy(name, a + 1, b - a - 1); name[b - a - 1] = 0;
    snprintf(path, sizeof path, "%s/%s", g_dir, name);
    long len = 0;
    char *c = slurp(path, &len);
    for (long i = 0; c && i < len; i++) h = (h ^ (unsigned char)c[i]) * 1099511628211ull;
    h = (h ^ (c ? 1 : 0)) * 1099511628211ull;
    free(c);
  }
  return h;
}
static uint64_t bcf_done_hash;  /* the datasources as of the last biber run (or the start) */

static int run_bibtex(void) { return run_prog(bibtex); }

/* What the last rule step did, for --serve's events. */
static int step_bibtex_ran, step_bibtex_code, step_bbl_changed, step_bbl_rerun, step_j;
static int step_bib_ran;           /* BibTeX or biber ran (step_bibtex_ran counts makeindex too): a new .blg (C14) */
static char step_tool[64];         /* the programs that ran, comma-separated: bibtex, biber, makeindex, makeglossaries */
static void step_ran(const char *tool) {
  if (strstr(step_tool, tool)) return;
  size_t n = strlen(step_tool);
  snprintf(step_tool + n, sizeof step_tool - n, "%s%s", n ? "," : "", tool);
}

/* latexmk's rule, one step, after run `seq` ended: write back what changed, BibTeX if needed, and if a file the run
   read changed, start the next run (rolled back to the latest snapshot before the first changed byte). Returns the
   new run's seq, or -1 when there is nothing left to do. `runs` counts the runs of this compile so far. */
static int rule_step(int seq, int runs) {
  struct change *ch = NULL;
  int nch = 0, cap = 0;
  char wdir[PATH_MAX];
  step_bibtex_ran = step_bbl_changed = step_bbl_rerun = step_bib_ran = 0;
  step_tool[0] = 0;
  step_bibtex_code = 0;
  snprintf(wdir, sizeof wdir, "%s/w-%d", outdir, seq);
  char *oldbib = bib_state(), *newbib = NULL;
  DIR *d = opendir(wdir);
  struct dirent *de;
  while (d && (de = readdir(d))) {
    if (de->d_name[0] == '.') continue;
    char rel[PATH_MAX], *o = rel;
    for (const char *q = de->d_name; *q && o < rel + sizeof rel - 1; q++) {
      if (!strncmp(q, "%2F", 3)) { *o++ = '/'; q += 2; } else *o++ = *q;
    }
    *o = 0;
    if (strlen(rel) > 4 && !strcmp(rel + strlen(rel) - 4, ".tmp")) continue;
    char wp[PATH_MAX], dp[PATH_MAX];
    snprintf(wp, sizeof wp, "%s/%s", wdir, de->d_name);
    snprintf(dp, sizeof dp, "%s/%s", g_dir, rel);
    long ln = 0, lo = 0;
    char *nw = slurp(wp, &ln), *old = slurp(dp, &lo);
    if (!nw) { free(old); continue; }
    if (!old || lo != ln || memcmp(old, nw, ln)) {
      add_change(&ch, &nch, &cap, rel, first_diff(old, lo, nw, ln));
      spit(dp, nw, ln);
    }
    free(nw); free(old);
  }
  if (d) closedir(d);
  newbib = bib_state();
  int has_bibdata = strstr(newbib, "\\bibdata{") != NULL;
  char bcfp[PATH_MAX];
  snprintf(bcfp, sizeof bcfp, "%s/%s.bcf", g_dir, job);
  long bcfl = 0;
  char *bcf = biber ? slurp(bcfp, &bcfl) : NULL;
  if (bcf) { /* biblatex with biber: latexmk runs biber instead of BibTeX */
    char bblp[PATH_MAX], bcfrel[PATH_MAX];
    snprintf(bblp, sizeof bblp, "%s/%s.bbl", g_dir, job);
    snprintf(bcfrel, sizeof bcfrel, "%s.bcf", job);
    int bcf_changed = 0;
    for (int c = 0; c < nch; c++) if (!strcmp(ch[c].rel, bcfrel)) bcf_changed = 1;
    long lo = 0, ln = 0;
    char *oldbbl = slurp(bblp, &lo);
    uint64_t bh = bcf_sources_hash(bcf);
    if (!oldbbl || bcf_changed || bh != bcf_done_hash) {
      step_bibtex_code = run_prog(biber);
      step_bibtex_ran = step_bib_ran = 1;
      step_ran("biber");
      bcf_done_hash = bh;
      char *nbbl = slurp(bblp, &ln);
      if (nbbl && (!oldbbl || lo != ln || memcmp(oldbbl, nbbl, ln))) {
        char bblrel[PATH_MAX];
        step_bbl_changed = 1;
        snprintf(bblrel, sizeof bblrel, "%s.bbl", job);
        add_change(&ch, &nch, &cap, bblrel, first_diff(oldbbl, lo, nbbl, ln));
      }
      free(nbbl);
    }
    free(oldbbl);
    free(bcf);
    has_bibdata = 0;  /* not BibTeX's */
  }
  /* BibTeX */
  if (bibtex && has_bibdata && bib_files_exist(newbib)) {
    char bblp[PATH_MAX];
    snprintf(bblp, sizeof bblp, "%s/%s.bbl", g_dir, job);
    long lo = 0, ln = 0;
    char *oldbbl = slurp(bblp, &lo);
    uint64_t bh = bib_sources_hash(newbib);
    if (!oldbbl || strcmp(oldbib, newbib) || bh != bib_done_hash) {
      step_bibtex_code = run_bibtex();
      step_bibtex_ran = step_bib_ran = 1;
      step_ran("bibtex");
      bib_done_hash = bh;
      char *nbbl = slurp(bblp, &ln);
      if (nbbl && (!oldbbl || lo != ln || memcmp(oldbbl, nbbl, ln))) {
        char bblrel[PATH_MAX];
        step_bbl_changed = 1;
        snprintf(bblrel, sizeof bblrel, "%s.bbl", job);
        add_change(&ch, &nch, &cap, bblrel, first_diff(oldbbl, lo, nbbl, ln));
      }
      free(nbbl);
    }
    free(oldbbl);
  }
  free(oldbib); free(newbib);
  { /* makeindex, makeglossaries */
    char in[16][64], out[16][64];
    int gloss[16], n = idx_rules(in, out, gloss, 16), gloss_done = 0;
    for (int r = 0; r < n; r++) {
      char ip[PATH_MAX], op[PATH_MAX];
      snprintf(ip, sizeof ip, "%s/%s", g_dir, in[r]);
      snprintf(op, sizeof op, "%s/%s", g_dir, out[r]);
      if (access(ip, F_OK)) continue;
      uint64_t h = file_hash(in[r]), *d = idx_done(in[r]);
      if (access(op, F_OK) == 0 && d && *d == h) continue;
      long lo = 0, ln = 0;
      char *old = slurp(op, &lo);
      if (!gloss[r]) {
        char *argv[] = {(char *)makeindex, "-o", out[r], in[r], NULL};
        step_bibtex_code = run_argv_in_project(argv);
        step_ran("makeindex");
      } else if (!gloss_done) {  /* one makeglossaries call does every glossary */
        char *argv[] = {"perl", (char *)makeglossaries, job, NULL};
        step_bibtex_code = run_argv_in_project(argv);
        step_ran("makeglossaries");
        gloss_done = 1;
      }
      step_bibtex_ran = 1;
      for (int r2 = 0; r2 < n; r2++)  /* every input this program has now seen */
        if (gloss[r2] == gloss[r]) { uint64_t *d2 = idx_done(in[r2]); if (d2) *d2 = file_hash(in[r2]); }
      char *nw = slurp(op, &ln);
      if (nw && (!old || lo != ln || memcmp(old, nw, ln))) {
        add_change(&ch, &nch, &cap, out[r], first_diff(old, lo, nw, ln));
      }
      free(old); free(nw);
    }
  }
  /* rerun? */
  char logp[PATH_MAX];
  snprintf(logp, sizeof logp, "%s/final-%d.log", outdir, seq);
  long ll = 0;
  char *log = slurp(logp, &ll);
  int j = -1; long kk = 0; const char *rr = NULL;
  for (int c = 0; c < nch; c++) {
    char nofile[PATH_MAX + 16];
    snprintf(nofile, sizeof nofile, "No file %s.", ch[c].rel);
    int missed = !fin_read(ch[c].rel) && log && strstr(log, nofile);
    if (!fin_read(ch[c].rel) && !missed) continue;
    /* The run looked for it and found nothing: what it saw differs from byte 0, whatever the disk had before (an
       earlier compile may have written it while this run resumed from a snapshot older than that). */
    if (missed) ch[c].k = 0;
    int js = snap_before(ch[c].rel, ch[c].k);
    if (missed) { /* where was the lookup? If no snapshot saw it (an existence test that bypasses the open hook,
                     e.g. \pdffilesize), start over from the first snapshot */
      int seen = 0;
      for (int s2 = 0; s2 < nsnaps && !seen; s2++) seen = ext_of(&snaps[s2], ch[c].rel) > 0;
      if (!seen && nsnaps > 0) js = 0;
    }
    if (getenv("TAUDOT_DEBUG"))
      fprintf(stderr, "rule: run %d: %s changed at %ld (read %d, missed %d) -> snapshot %d of %d\n", seq, ch[c].rel,
              ch[c].k, fin_read(ch[c].rel), missed, js, nsnaps);
    if (js >= 0 && (j < 0 || js < j)) { j = js; kk = ch[c].k; rr = ch[c].rel; }
  }
  if (getenv("TAUDOT_DEBUG"))
    for (int c = 0; c < nch; c++) fprintf(stderr, "rule: run %d: changed %s\n", seq, ch[c].rel);
  free(log);
  if (j < 0 || runs >= max_runs) { free(ch); return -1; }
  step_bbl_rerun = rr && strlen(rr) > 4 && !strcmp(rr + strlen(rr) - 4, ".bbl");
  char rrbuf[PATH_MAX];
  snprintf(rrbuf, sizeof rrbuf, "%s", rr);  /* rr points into ch */
  rr = rrbuf;
  free(ch);
  step_j = j;
  seq = ++runseq;
  rollback(j, seq, rr, kk);
  drop_after(j);
  want_seq = seq;
  return seq;
}

/* After run `seq` ended: latexmk's rule until it has nothing left to do. Returns the seq of the last run; counts
   runs (including the first) and BibTeX calls. */
static int converge(int seq, int *runs, int *bibs, uint64_t *t_end) {
  *runs = 1; *bibs = 0; *t_end = tE;
  for (;;) {
    int next = rule_step(seq, *runs);
    *bibs += step_bibtex_ran;
    if (next < 0) return seq;
    seq = next;
    if (!pump(c_E, 120000)) { fprintf(stderr, "rerun %d timed out\n", seq); return seq; }
    (*runs)++;
    *t_end = tE;
  }
}

static void snap_cap_from_env(void) {
  const char *s = getenv("TAUDOT_MAX_SNAPSHOTS");
  if (s && atoi(s) >= 4) snap_cap = atoi(s) < MAXSNAP ? atoi(s) : MAXSNAP;
}

static void killall_engine(void) {
  for (int i = 0; i < nsnaps; i++) sig(snaps[i].pid, snaps[i].start, SIGKILL);
  if (runner) sig_runner(SIGKILL);
  if (engine_root) sig(engine_root, root_start, SIGKILL);
}

#include "serve.c"

int main(int argc, char **argv) {
  for (int k = 1; k < argc && argv[k][0] == '-'; k++)
    if (!strcmp(argv[k], "--serve")) return serve_main(argc, argv);
  const char *engine = getenv("TAUDOT_PDFTEX"), *fmt = "pdflatex";
  const char *snap_ms = NULL;
  snap_cap_from_env();
  int i = 1;
  for (; i < argc && argv[i][0] == '-' && argv[i][1] == '-'; i++) {
    if (!strcmp(argv[i], "--engine") && i + 1 < argc) engine = argv[++i];
    else if (!strcmp(argv[i], "--fmt") && i + 1 < argc) fmt = argv[++i];
    else if (!strcmp(argv[i], "--snapshot-ms") && i + 1 < argc) snap_ms = argv[++i];
    else if (!strcmp(argv[i], "--finish-all")) finish_all = 1;
    else if (!strcmp(argv[i], "--leave")) leave = 1;
    else if (!strcmp(argv[i], "--bibtex") && i + 1 < argc) bibtex = argv[++i];
    else if (!strcmp(argv[i], "--synctex") && i + 1 < argc) synctex = argv[++i];
    else if (!strcmp(argv[i], "--biber") && i + 1 < argc) biber = argv[++i];
    else if (!strcmp(argv[i], "--makeindex") && i + 1 < argc) makeindex = argv[++i];
    else if (!strcmp(argv[i], "--makeglossaries") && i + 1 < argc) makeglossaries = argv[++i];
    else if (!strcmp(argv[i], "--max-runs") && i + 1 < argc) max_runs = atoi(argv[++i]);
    else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
  }
  if (argc - i != 4 || !engine) {
    fprintf(stderr, "usage: %s [--engine PATH] [--fmt NAME] [--snapshot-ms N] [--finish-all] [--leave] [--bibtex PATH] [--biber PATH] [--makeindex PATH] [--makeglossaries SCRIPT] [--synctex N] "
                    "[--max-runs N] DIR MAIN.tex EDITS OUT\n",
            argv[0]);
    return 2;
  }
  char dir[PATH_MAX], out[PATH_MAX];
  mkdir(argv[i + 3], 0755);
  if (!realpath(argv[i], dir) || !realpath(argv[i + 3], out)) die("realpath");
  const char *main_tex = argv[i + 1], *edits_path = argv[i + 2];
  outdir = out;
  snprintf(g_dir, sizeof g_dir, "%s", dir);
  snprintf(job, sizeof job, "%s", main_tex);
  if (strlen(job) > 4 && !strcmp(job + strlen(job) - 4, ".tex")) job[strlen(job) - 4] = 0;
  snprintf(ctl, sizeof ctl, "%s/ctl", out);
  unlink(ctl);

  int sv[2];
  if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv)) die("socketpair");
  int big = 1 << 20;
  for (int k = 0; k < 2; k++) {
    setsockopt(sv[k], SOL_SOCKET, SO_SNDBUF, &big, sizeof big);
    setsockopt(sv[k], SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
  }
  sock = sv[0];
  double load[3];
  getloadavg(load, 3);
  printf("run\tdir=%s\tmain=%s\tsnapshot_ms=%s\tload=%.2f %.2f %.2f\n", dir, main_tex, snap_ms ? snap_ms : "50", load[0],
         load[1], load[2]);
  fflush(stdout);

  { /* the project's .bbl is taken as current for its .bib files as they are now */
    char *bl = bib_state();
    bib_done_hash = bib_sources_hash(bl);
    free(bl);
    char bcfp[PATH_MAX];
    long n = 0;
    snprintf(bcfp, sizeof bcfp, "%s/%s.bcf", g_dir, job);
    char *bcf = slurp(bcfp, &n);
    bcf_done_hash = bcf_sources_hash(bcf);
    free(bcf);
    idx_init();
  }
  uint64_t t_start = now_us();
  pid_t pid = fork();
  if (pid < 0) die("fork");
  if (pid == 0) {
    char fdbuf[16];
    snprintf(fdbuf, sizeof fdbuf, "%d", sv[1]);
    close(sv[0]);
    setenv("TAUDOT_LIVE_FD", fdbuf, 1);
    setenv("TAUDOT_PROJECT", dir, 1);
    setenv("TAUDOT_LIVE_OUT", out, 1);
    if (snap_ms) setenv("TAUDOT_SNAPSHOT_MS", snap_ms, 1);
    if (finish_all) setenv("TAUDOT_FINISH_ALL", "1", 1);
    if (chdir(dir)) die("chdir");
    char log[PATH_MAX];
    snprintf(log, sizeof log, "%s/engine.out", out);
    int fd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
    int nul = open("/dev/null", O_RDONLY);
    if (nul >= 0) { dup2(nul, 0); close(nul); }
    char fmtarg[256];
    snprintf(fmtarg, sizeof fmtarg, "-fmt=%s", fmt);
    if (synctex) {
      char sarg[32];
      snprintf(sarg, sizeof sarg, "-synctex=%s", synctex);
      execl(engine, engine, fmtarg, "-interaction=batchmode", sarg, main_tex, (char *)NULL);
    }
    execl(engine, engine, fmtarg, "-interaction=batchmode", main_tex, (char *)NULL);
    _exit(127);
  }
  close(sv[1]);
  engine_root = runner = pid;
  root_start = runner_start = proc_start(pid);

  want_seq = 0;
  if (!pump(c_E, 120000)) { fprintf(stderr, "first run did not end\n"); killall_engine(); return 1; }
  printf("first\tpages=%d\tcode=%d\tms=%.1f\tfirst_page_ms=%.1f\tsnapshots=%d\tpdf=%s/final-0.pdf\n", Epages, Ecode,
         (tE - t_start) / 1000.0, (tfirst_page - t_start) / 1000.0, nsnaps, out);
  {
    int runs, bibs;
    uint64_t te;
    int last = converge(0, &runs, &bibs, &te);
    last_seq = last;
    printf("first-converged\truns=%d\tbibtex=%d\tms=%.1f\tfinal=%s/final-%d.pdf\n", runs, bibs, (te - t_start) / 1000.0,
           out, last);
  }
  if (finish_all) {
    pump(c_E, 2000);  /* let the last finishes arrive */
    usleep(500000);
    pump(c_E, 10);
    static char buf[1 << 16];
    for (;;) {
      ssize_t n = recv(sock, buf, sizeof buf - 1, MSG_DONTWAIT);
      if (n <= 0) break;
      buf[n] = 0;
      handle(buf);
    }
    for (int k = 0; k < nallP; k++)
      printf("finish\tpages=%d\tfork_ms=%.2f\tfinish_ms=%.2f\twrite_ms=%.2f\tpdf=%s/%s\n", allP[k].pages,
             (allP[k].t1 - allP[k].t0) / 1000.0, (allP[k].t2 - allP[k].t1) / 1000.0, (allP[k].t3 - allP[k].t2) / 1000.0,
             out, allP[k].name);
  }
  memory("after first run");
  fflush(stdout);

  FILE *ef = fopen(edits_path, "r");
  if (!ef) die(edits_path);
  char line[1 << 16];
  int seq;
  printf("edit\tseq\tlabel\tfile\tbyte\tsnap_age_ms\tsnaps_dropped\tresume_ms\tpdf_ms\tfinish_ms\tpdf_pages\tfull_ms\tpages\tpdf\t"
         "runs\tbibtex\tconverged_ms\tfinal\n");
  while (fgets(line, sizeof line, ef)) {
    line[strcspn(line, "\n")] = 0;
    if (!line[0] || line[0] == '#') continue;
    char *f[4];
    int nf = 0;
    char *p = line;
    while (nf < 4) {
      f[nf++] = p;
      p = strchr(p, '\t');
      if (!p) break;
      *p++ = 0;
    }
    if (nf != 4) { fprintf(stderr, "bad edit line: %s\n", line); continue; }
    for (int k = 1; k < 4; k++) unescape(f[k]);
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, f[1]);
    long len;
    char *old = slurp(path, &len);
    if (!old) { fprintf(stderr, "no file %s\n", path); continue; }
    char *at = strstr(old, f[2]);
    if (!at) { fprintf(stderr, "%s: not found in %s: %s\n", f[0], f[1], f[2]); free(old); continue; }
    long ls = strlen(f[2]), lr = strlen(f[3]);
    long nlen = len - ls + lr;
    char *nw = malloc(nlen + 1);
    memcpy(nw, old, at - old);
    memcpy(nw + (at - old), f[3], lr);
    memcpy(nw + (at - old) + lr, at + ls, len - (at - old) - ls);
    long k = first_diff(old, len, nw, nlen);
    seq = ++runseq;

    size_t fl = strlen(f[1]);
    if (fl > 4 && !strcmp(f[1] + fl - 4, ".bib") && !fin_read(f[1])) {
      /* a file the engine never reads: write it, then latexmk's rule (BibTeX; a rerun only if the .bbl changed) */
      uint64_t t0 = now_us();
      spit(path, nw, nlen);
      int runs, bibs;
      uint64_t te = t0;
      int prev = last_seq;
      int last = converge(last_seq, &runs, &bibs, &te);
      last_seq = last;
      runs -= 1;  /* converge counts the run it started from, which was the previous compile's */
      double ms = (te > t0 ? te - t0 : now_us() - t0) / 1000.0;
      printf("edit\t%d\t%s\t%s\t%ld\t0\t0\t0\t%.1f\t0\t%d\t%.1f\t%d\t%s/%s\t%d\t%d\t%.1f\t%s/final-%d.pdf\n",
             seq, f[0], f[1], k, ms, last != prev ? lastP.pages : 0, ms, Epages, out,
             last != prev ? lastP.name : "-", runs, bibs, ms, out, last);
      fflush(stdout);
      free(old); free(nw);
      continue;
    }
    int j = snap_before(f[1], k);
    if (j < 0) { fprintf(stderr, "%s: no snapshot before byte %ld\n", f[0], k); free(old); free(nw); break; }
    rollback(j, seq, f[1], k);

    uint64_t t0 = now_us();
    spit(path, nw, nlen);
    int dropped = nsnaps - 1 - j;
    drop_after(j);
    want_seq = seq;
    uint64_t age = snaps[j].t;
    if (!pump(c_PE, 120000)) {
      fprintf(stderr, "%s: timed out (R=%d P=%d E=%d)\n", f[0], gotR, gotP, gotE);
      printf("edit\t%d\t%s\t%s\t%ld\tTIMEOUT\n", seq, f[0], f[1], k);
      fflush(stdout);
      free(old); free(nw);
      continue;
    }
    double full_ms = (tE - t0) / 1000.0;
    int epages = Epages;
    struct pmsg firstP = lastP;  /* reruns overwrite lastP */
    int runs, bibs;
    uint64_t te;
    int last = converge(seq, &runs, &bibs, &te);
    last_seq = last;
    printf("edit\t%d\t%s\t%s\t%ld\t%.1f\t%d\t%.1f\t%.1f\t%.1f\t%d\t%.1f\t%d\t%s/%s\t%d\t%d\t%.1f\t%s/final-%d.pdf\n", seq,
           f[0], f[1], k, (t0 - age) / 1000.0, dropped, (tR - t0) / 1000.0, (firstP.t3 - t0) / 1000.0,
           (firstP.t2 - firstP.t1) / 1000.0, firstP.pages, full_ms, epages, out, firstP.name, runs, bibs, (te - t0) / 1000.0,
           out, last);
    fflush(stdout);
    free(old);
    free(nw);
  }
  fclose(ef);
  memory("after edits");
  if (leave) {
    printf("leave\tpids=");
    for (int i = 0; i < nsnaps; i++) printf("%d ", snaps[i].pid);
    printf("%d %d\n", runner, engine_root);
    fflush(stdout);
    _exit(0);
  }
  killall_engine();
  while (waitpid(-1, NULL, WNOHANG) > 0) ;
  return 0;
}
