// MIT. libtau-interpose: live typesetting for unmodified TeX engines, from below (DYLD_INSERT_LIBRARIES).
//
// - Project files (anything under TAU_PROJECT, default the start directory) are served from memory, one line per
//   read(), so every refill of TeX's stdio buffer is a line start: the read log (extent per file) is exact and a
//   fork there is a clean snapshot (the FILE buffer is empty).
// - Files written under the project stay in memory (forked copy-on-write with the process) and shadow the disk;
//   at exit they go to TAU_OUT/<tag>-<seq>-<pid>/.
// - Other files opened for reading get their own file description after every fork, at the same offset, so a
//   runner never moves a parked snapshot's offsets.
// - With TAU_FD (a pipe to the driver): snapshots by fork() at project-file line reads, at most every
//   TAU_SNAPSHOT_MS; a parked snapshot resumes on SIGUSR1 with the commands in TAU_OUT/ctl-<pid>.
// - Magic paths under /.taudot/ (stat/open/access): signals from the TeX side (the shipout hook).
// Docs: docs/universal.md.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <spawn.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
extern char **environ;

#define INTERPOSE(rep, orig) \
  __attribute__((used)) static struct { const void *r, *o; } _ip_##rep \
      __attribute__((section("__DATA,__interpose"))) = {(const void *)rep, (const void *)orig}

extern int open_nc(const char *, int, ...) __asm("_open$NOCANCEL");
extern int openat_nc(int, const char *, int, ...) __asm("_openat$NOCANCEL");
extern ssize_t read_nc(int, void *, size_t) __asm("_read$NOCANCEL");
extern ssize_t write_nc(int, const void *, size_t) __asm("_write$NOCANCEL");
extern ssize_t pread_nc(int, void *, size_t, off_t) __asm("_pread$NOCANCEL");
extern int close_nc(int) __asm("_close$NOCANCEL");
extern int fcntl_nc(int, int, ...) __asm("_fcntl$NOCANCEL");

// ---------------------------------------------------------------------------------------------------- state

typedef struct {
  char *rel;          // path relative to the project
  char *data;         // contents (NULL: missing)
  size_t len, cap;
  int written;        // made by this run (shadows the disk)
  int missing;        // looked up and not found
  long extent;        // bytes read, +1 if the end was seen (-1: never read)
  int binary;         // no line mode, no snapshots
  int mapped;         // data is a VM reservation (grows in place: no copy, so forks share untouched pages)
} mfile;

#define RESERVE ((size_t)1 << 30)
static void free_data(mfile *f) {
  if (f->mapped) munmap(f->data, RESERVE);
  else free(f->data);
  f->data = NULL;
  f->len = f->cap = 0;
  f->mapped = 0;
}

typedef struct {
  int used;
  mfile *f;
  size_t pos;
  int wr;
  size_t fin_off;  // finisher: how much of finish_text this fd has served
} mfd;

typedef struct {
  int fd, flags;
  char *path;
} rfd;

#define MAXFD 4096
static mfd fds[MAXFD];
static mfile **files;
static int nfiles, capfiles;
static rfd *rfds;
static int nrfds, caprfds;

static char proj[1024], cwd0[1024];
static size_t projlen;
static char out[1024];
static int tau_fd = -1, life_fd = -1;
static long snap_us = 50000;
static int64_t last_snap;
static int inited;
static int seq;             // the edit this process's run belongs to
static int pages;           // shipouts seen (the TeX side's hook)
static int eof_all;         // finisher: the next project text read gets finish_text, then every one is at its end
static const char *finish_text =  // discard the page in progress, then TeX's own \end: a clean stop
    "\\output={\\setbox0\\box255 \\deadcycles=0\\relax}\\csname @@end\\endcsname\n";
static char edit_rel[1024]; // the run has passed the edit once this file's extent is past edit_pos
static long edit_pos = -1;
static int passed = 1;
static int finish_every;    // fork a finisher at every shipout once passed
static int finish_next;     // fork one at the next shipout
static int finish_rule;     // the first shipout past the edit, then at most every finish_period_us
static int64_t finish_period_us = 150000, last_finish;
static volatile sig_atomic_t finish_asap;  // SIGUSR2 from the driver ("finish"): at the next safe point
static void on_usr2(int sig) { (void)sig; finish_asap = 1; }
static int goal_page(void) {  // TAU_OUT/goal: the last page in view, 0-based (-1: the whole document)
  char p[2048], b[32];
  snprintf(p, sizeof p, "%s/goal", out);
  int fd = open_nc(p, O_RDONLY), g = -1;
  if (fd >= 0) {
    ssize_t n = read_nc(fd, b, sizeof b - 1);
    if (n > 0) { b[n] = 0; g = atoi(b); }
    close_nc(fd);
  }
  return g;
}
static const char *tag = "run";
static int is_runner = 1;
static long dense_lo = -1, dense_hi = -1;  // snapshot at every line read of dense_rel in [lo, hi)
static char dense_rel[1024];
static long mark_lo = -1, mark_hi = -1;  // a snapshot (no warm pass) at line reads of mark_rel in [lo, hi): TAU_MARK
static char mark_rel[1024];
static int para_stop;       // paragraph pass: exit at the /.taudot/stop signal
static int para_mode;       // paragraph pass: other project text files are at their end
static mfile *para_file, *para_out;
static size_t para_base;    // the output's length when the pass began: what follows is the pass's page
static size_t para_end;     // where the flush line starts in the pass's file
static int64_t t_para_flush, t_para_start;
static long para_flt_wake = -1;
static int64_t t_mark[8];  // TAU_PHASES: \taudotmark{N} in the flush (0 before \par, 1 after, 2 lines taken)
static char snap_rel[1024]; // the file being read when this snapshot was taken, and where
static long snap_pos = -1;
static int64_t t0;
static int64_t t_fork, t_inject;  // finisher timings
static int exit_code;             // the engine's status, for the driver's done event
static FILE *stream_of[MAXFD];  // the FILE over each fd (fopen/fdopen), for fix_lock
static int reading_fd = -1;     // the fd mem_read is serving (its FILE is locked by getc/fgets right now)
static char tlroot[1024];   // TAU_TLROOT: a TeX Live tree filled on demand by TAU_FETCH (warm-up only)
static const char *fetch_cmd;
static char **fetch_failed;
static int nfailed;

static int64_t now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void msg(const char *fmt, ...) {
  if (tau_fd < 0) return;
  char b[512];
  va_list a;
  va_start(a, fmt);
  int n = vsnprintf(b, sizeof b - 1, fmt, a);
  va_end(a);
  if (n > (int)sizeof b - 2) n = sizeof b - 2;
  b[n++] = '\n';
  write(tau_fd, b, n);  // a pipe: writes up to PIPE_BUF (512) are atomic
}

static const char *bin_ext[] = {".pdf", ".png", ".jpg", ".jpeg", ".eps", ".ps", ".ttf", ".otf", ".pfb", ".tfm",
                                ".gz", ".zip", ".svg", ".gif", ".tif", ".tiff", ".jbig2", ".jb2", ".mps", 0};

static int is_binary(const char *rel) {
  const char *d = strrchr(rel, '.');
  if (!d) return 0;
  for (int i = 0; bin_ext[i]; i++)
    if (!strcasecmp(d, bin_ext[i])) return 1;
  return 0;
}

// Normalise PATH (relative to the cwd, which TeX never changes) and return it relative to the project, or NULL.
static const char *project_rel(const char *path, char *buf, size_t n) {
  if (!inited || !path) return NULL;
  char tmp[2048];  // no snprintf here: open() is called under libc's locale lock (setlocale)
  size_t a = 0, pl = strlen(path);
  if (path[0] != '/') {
    size_t cl = strlen(cwd0);
    if (cl + 1 >= sizeof tmp) return NULL;
    memcpy(tmp, cwd0, cl);
    tmp[cl] = '/';
    a = cl + 1;
  }
  if (a + pl >= sizeof tmp) return NULL;
  memcpy(tmp + a, path, pl + 1);
  // collapse "//", "/./"; refuse ".."
  char *w = buf, *end = buf + n - 1;
  const char *p = tmp;
  while (*p && w < end) {
    if (p[0] == '/' && p[1] == '/') { p++; continue; }
    if (p[0] == '/' && p[1] == '.' && (p[2] == '/' || p[2] == 0)) { p += 2; continue; }
    if (p[0] == '/' && p[1] == '.' && p[2] == '.' && (p[3] == '/' || p[3] == 0)) return NULL;
    *w++ = *p++;
  }
  *w = 0;
  if (strncmp(buf, proj, projlen) || buf[projlen] != '/') return NULL;
  return buf + projlen + 1;
}

static mfile *find_file(const char *rel) {
  for (int i = 0; i < nfiles; i++)
    if (!strcmp(files[i]->rel, rel)) return files[i];
  return NULL;
}

static int load_disk(mfile *f) {  // (re)read F from the project directory
  char p[2048];
  snprintf(p, sizeof p, "%s/%s", proj, f->rel);
  int fd = open_nc(p, O_RDONLY);
  free_data(f);
  if (fd < 0) { f->missing = 1; return -1; }
  struct stat st;
  if (fstat(fd, &st) || !S_ISREG(st.st_mode)) { close(fd); f->missing = 1; return -1; }
  f->cap = st.st_size + 1;
  f->data = malloc(f->cap);
  size_t got = 0;
  while (got < (size_t)st.st_size) {
    ssize_t r = read_nc(fd, f->data + got, st.st_size - got);
    if (r <= 0) break;
    got += r;
  }
  close(fd);
  f->len = got;
  f->missing = 0;
  return 0;
}

static mfile *get_file(const char *rel, int create) {
  mfile *f = find_file(rel);
  if (f) return f;
  f = calloc(1, sizeof *f);
  f->rel = strdup(rel);
  f->extent = -1;
  f->binary = is_binary(rel);
  if (!create) load_disk(f);
  if (nfiles == capfiles) {
    capfiles = capfiles ? capfiles * 2 : 64;
    files = realloc(files, capfiles * sizeof *files);
  }
  files[nfiles++] = f;
  return f;
}

static void note_extent(mfile *f, long e) {
  if (e > f->extent) f->extent = e;
  if (!passed && !strcmp(f->rel, edit_rel) && f->extent > edit_pos) passed = 1;
}

// ---------------------------------------------------------------------------------------------------- forks

// A fork inside read() happens under the FILE's lock (getc holds it); the child's thread has a new id, so it could
// never release it. Make the child the lock's owner, held once, as the parent's frame expects. The layout of
// struct __sFILEX (Libc's local.h: `unsigned char *up; pthread_mutex_t fl_mutex; ...`) has been stable for years.
struct sfilex_head {
  unsigned char *up;
  pthread_mutex_t fl_mutex;
};
static pthread_mutex_t *stream_lock(void) {
  if (reading_fd < 0 || reading_fd >= MAXFD || !stream_of[reading_fd]) return NULL;
  struct sfilex_head *x = (struct sfilex_head *)stream_of[reading_fd]->_extra;
  return x ? &x->fl_mutex : NULL;
}
static int lock_depth;
static void measure_lock(void) {  // before fork: how many times does this thread hold the stream's lock?
  pthread_mutex_t *m = stream_lock();
  lock_depth = 0;
  if (!m) {
    if (getenv("TAU_DEBUG")) write(2, "tau: no stream\n", 15);
    return;
  }
  while (pthread_mutex_unlock(m) == 0) lock_depth++;  // a recursive mutex: EPERM once we no longer own it
  for (int i = 0; i < lock_depth; i++) pthread_mutex_lock(m);
  if (getenv("TAU_DEBUG")) {
    char b[128];
    int n = snprintf(b, sizeof b, "tau: fd %d lock depth %d\n", reading_fd, lock_depth);
    write(2, b, n);
  }
}
static void fix_lock(void) {  // after fork, in the child: own it as deeply
  pthread_mutex_t *m = stream_lock();
  if (!m) return;
  pthread_mutex_t init = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
  *m = init;
  for (int i = 0; i < lock_depth; i++) pthread_mutex_lock(m);
}

static void reopen_real_fds(void) {
  fix_lock();  // give this process its own descriptions of the files it reads
  for (int i = 0; i < nrfds; i++) {
    rfd *r = &rfds[i];
    off_t off = lseek(r->fd, 0, SEEK_CUR);
    int nfd = open_nc(r->path, r->flags & ~(O_CREAT | O_TRUNC | O_EXCL));
    if (nfd < 0) continue;
    if (off > 0) lseek(nfd, off, SEEK_SET);
    int cloexec = fcntl_nc(r->fd, F_GETFD) & FD_CLOEXEC;
    dup2(nfd, r->fd);
    close_nc(nfd);
    if (cloexec) fcntl_nc(r->fd, F_SETFD, FD_CLOEXEC);
  }
}

static void write_extents(int pid) {
  char p[2048], b[4096];
  snprintf(p, sizeof p, "%s/s-%d", out, pid);
  int fd = open_nc(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;
  if (snap_pos >= 0) {
    int n = snprintf(b, sizeof b, "C %ld %s\n", snap_pos, snap_rel);
    write_nc(fd, b, n);
  }
  {
    int n = snprintf(b, sizeof b, "P %d\n", pages);  // pages shipped before this point
    write_nc(fd, b, n);
  }
  for (int i = 0; i < nfiles; i++) {
    mfile *f = files[i];
    if (f->extent < 0 && !f->missing) continue;
    int n = snprintf(b, sizeof b, "%ld %d %d %s\n", f->extent, f->written, f->missing, f->rel);
    write_nc(fd, b, n);
  }
  close_nc(fd);
}

static void dump_outputs(int announce);

// Commands in TAU_OUT/ctl-<pid> (written by the driver before it signals): one per line.
//   seq N            the run's edit number
//   load REL         reread REL from the project directory (the driver changed it)
//   edit REL POS     the run has "passed" the edit once REL's extent is past POS
//   finish every|next|none
//   eof              finisher: every project text read is at its end from now on
//   stop             paragraph pass: exit at /.taudot/stop
//   dense REL LO HI  snapshot at every line read of REL in [LO, HI)
//   tag NAME         output folder prefix
static void read_ctl(int pid) {
  // Every source file from the clone: an older snapshot (resumed for a rerun) may hold text from before later edits
  // past what it read; what it read is unchanged (else the driver wouldn't have chosen it).
  for (int i = 0; i < nfiles; i++)
    if (!files[i]->written && !files[i]->binary) load_disk(files[i]);
  char p[2048];
  snprintf(p, sizeof p, "%s/ctl-%d", out, pid);
  int fd = open_nc(p, O_RDONLY);
  if (fd < 0) return;
  char b[65536];
  ssize_t n = read_nc(fd, b, sizeof b - 1);
  close_nc(fd);
  if (n <= 0) return;
  b[n] = 0;
  char *save, *line = strtok_r(b, "\n", &save);
  for (; line; line = strtok_r(NULL, "\n", &save)) {
    char a[1024];
    long x, y;
    if (sscanf(line, "seq %ld", &x) == 1) seq = (int)x;
    else if (sscanf(line, "load %1023[^\n]", a) == 1) {
      mfile *f = find_file(a);
      if (f && !f->written) load_disk(f);
    } else if (sscanf(line, "edit %1023s %ld", a, &x) == 2) {
      snprintf(edit_rel, sizeof edit_rel, "%s", a);
      edit_pos = x;
      mfile *f = find_file(a);
      passed = f && f->extent > x;
    } else if (!strcmp(line, "finish every")) finish_every = 1, finish_next = 0;
    else if (!strcmp(line, "finish next")) finish_next = 1;
    else if (!strcmp(line, "finish none")) finish_every = finish_next = finish_rule = 0;
    else if (!strcmp(line, "finish rule")) finish_rule = 1, finish_every = finish_next = 0, last_finish = 0;
    else if (!strcmp(line, "eof")) eof_all = 1;
    else if (!strcmp(line, "stop")) para_stop = 1;
    else if (sscanf(line, "snapms %ld", &x) == 1) {  // the interval from here on (a first run's may be sparser)
      snap_us = x * 1000;
      mark_lo = mark_hi = -1;
    } else if (sscanf(line, "dense %1023s %ld %ld", a, &x, &y) == 3) {
      snprintf(dense_rel, sizeof dense_rel, "%s", a);
      dense_lo = x, dense_hi = y;
    } else if (sscanf(line, "tag %63s", a) == 1) tag = strdup(a);
  }
}

static int is_output(const mfile *f);

// Paragraph pass (docs/universal.md): TAU_OUT/ctl-para-<pid> says which file was edited, where its paragraph ends
// in the new text, a line to insert here (the resume point: a line start) and a line to put after the paragraph.
static void para_setup(const char *p) {
  int fd = open_nc(p, O_RDONLY);
  if (fd < 0) _exit(1);
  static char b[65536];
  ssize_t n = read_nc(fd, b, sizeof b - 1);
  close_nc(fd);
  if (getenv("TAU_DEBUG")) {  // keep a copy of the orders
    char q[2100];
    snprintf(q, sizeof q, "%s.txt", p);
    int c = open_nc(q, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (c >= 0) { write_nc(c, b, n > 0 ? n : 0); close_nc(c); }
  }
  unlink(p);
  if (n <= 0) _exit(1);
  b[n] = 0;
  char *seg = NULL;  // after a "--" line: the new text from TP, TL bytes
  long tp = -1, tl = 0;
  char *sep = strstr(b, "\n--\n");
  if (sep) { *sep = 0; seg = sep + 4; }
  char rel[1024] = "", *prefix = NULL, *flush = NULL;
  long end = -1;
  char *save, *line = strtok_r(b, "\n", &save);
  for (; line; line = strtok_r(NULL, "\n", &save)) {
    long x;
    if (sscanf(line, "seq %ld", &x) == 1) seq = (int)x;
    else if (sscanf(line, "end %ld", &x) == 1) end = x;
    else if (sscanf(line, "text %ld %ld", &tp, &tl) == 2) {}
    else if (!strncmp(line, "file ", 5)) snprintf(rel, sizeof rel, "%s", line + 5);
    else if (!strncmp(line, "prefix ", 7)) prefix = line + 7;
    else if (!strncmp(line, "flush ", 6)) flush = line + 6;
  }
  mfile *f = find_file(rel);
  int rfd = -1;
  for (int i = 0; i < MAXFD && f; i++)
    if (fds[i].used && fds[i].f == f && !fds[i].wr) rfd = i;
  if (!f || rfd < 0 || !prefix || !flush) _exit(1);
  size_t P = fds[rfd].pos, E;
  const char *newtext;  // the new text from P on
  if (seg && tp == (long)P && seg + tl <= b + n) {
    newtext = seg;
    E = P + tl;
  } else {
    load_disk(f);
    E = end < 0 || (size_t)end > f->len ? f->len : (size_t)end;
    if (P > E) _exit(1);
    newtext = f->data + P;
  }
  size_t lp = strlen(prefix), lf = strlen(flush), need = E + lp + lf + 3;
  if (!f->mapped && f->data && f->cap >= need) {
    // in place: bytes before P are the same in the old and the new text (P <= the edit), and copying them into a
    // new buffer cost the whole file up to the paragraph (copy-on-write faults and all) on every pass
    char *d = f->data;
    memmove(d + P + lp + 1, newtext, E - P);  // (newtext may be d + P itself)
    memcpy(d + P, prefix, lp);
    d[P + lp] = '\n';
    memcpy(d + E + lp + 1, flush, lf);
    d[E + lp + 1 + lf] = '\n';
    f->len = E + lp + lf + 2;
  } else {
    char *d = malloc(need);
    memcpy(d, f->data, P);  // (bytes before P are the same in the old and the new text: P <= the edit)
    memcpy(d + P, prefix, lp);
    d[P + lp] = '\n';
    memcpy(d + P + lp + 1, newtext, E - P);
    memcpy(d + E + lp + 1, flush, lf);
    d[E + lp + 1 + lf] = '\n';
    free_data(f);
    f->data = d, f->len = E + lp + lf + 2, f->cap = f->len;
  }
  para_file = f;
  para_end = E + lp + 1;
  t_para_start = now_us();
  para_mode = para_stop = 1;
  is_runner = 0;
  tag = "para";
  for (int i = 0; i < nfiles; i++)
    if (files[i]->written && is_output(files[i])) para_out = files[i];
  for (int i = 0; i < MAXFD && para_out; i++)  // what the engine buffered before the snapshot is not ours
    if (fds[i].used && fds[i].f == para_out && fds[i].wr && stream_of[i]) fflush(stream_of[i]);
  para_base = para_out ? para_out->len : 0;
  alarm(2);  // never let a pass run on into the document
}

// Park as a snapshot: wait for SIGUSR1 (resume: fork a runner that reads the ctl) or the driver's exit.
// The kqueue is made before the snapshot is announced, so no SIGUSR1 can come before it is watched.
static int park_prepare(void) {
  int kq = kqueue();
  struct kevent ev[2];
  signal(SIGUSR1, SIG_IGN);  // kqueue still sees it
  EV_SET(&ev[0], SIGUSR1, EVFILT_SIGNAL, EV_ADD, 0, 0, 0);
  int nev = 1;
  if (life_fd >= 0) EV_SET(&ev[nev++], life_fd, EVFILT_READ, EV_ADD, 0, 0, 0);
  kevent(kq, ev, nev, NULL, 0, NULL);
  return kq;
}

static void watch_child(int kq, pid_t c) {
  struct kevent ev;
  EV_SET(&ev, c, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, 0);
  kevent(kq, &ev, 1, NULL, 0, NULL);
}

// The warm pass: a dense snapshot (at the edited line) keeps a child forked and its files reopened, parked until
// SIGUSR1 with orders in TAU_OUT/ctl-warm-<its pid>, so the next key's pass needn't wait for a fork.
static pid_t warm_pid;
static int dense_snap;

// The warm pass's wake (docs/universal.md). Copy-on-write faults after the wake were the cost, so while parked the
// child writes the pages the previous pass copied (TAU_OUT/hot; TAU_WARM_TOUCH=hot, the default; all; off).
// Measured and kept as switches, no gain: TAU_WARM_QOS=ui (user-interactive QoS, set in the exec'd engine: a forked
// child gets EPERM), TAU_WARM_PIPE=1 (blocking read() on a FIFO instead of kqueue + SIGUSR1).
static long minflt_now(void) {
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return ru.ru_minflt;
}

static long pretouch_hot(void) {  // the pages the last pass copied (TAU_OUT/hot), if still mapped and writable here
  char hp[2048];
  snprintf(hp, sizeof hp, "%s/hot", out);
  int fd = open_nc(hp, O_RDONLY);
  if (fd < 0) return 0;
  struct stat st;
  fstat(fd, &st);
  uint64_t *a = malloc(st.st_size + 8);
  ssize_t got = read_nc(fd, a, st.st_size);
  close_nc(fd);
  long n = 0, k = got > 0 ? got / 8 : 0;
  mach_vm_address_t lo = 0, hi = 0;
  int ok = 0;
  for (long i = 0; i < k; i++) {  // addresses ascend: one region lookup per region
    if (a[i] < lo || a[i] >= hi) {
      mach_vm_address_t addr = a[i];
      mach_vm_size_t size = 0;
      vm_region_basic_info_data_64_t info;
      mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
      mach_port_t obj;
      ok = mach_vm_region(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt,
                          &obj) == KERN_SUCCESS && addr <= a[i] && (info.protection & VM_PROT_WRITE) && !info.shared;
      lo = addr, hi = addr + size;
      if (addr > a[i]) { lo = a[i]; hi = addr; ok = 0; }
    }
    if (ok) {
      volatile char *q = (volatile char *)a[i];
      *q = *q;
      n++;
    }
  }
  free(a);
  return n;
}

static long pretouch(void) {  // returns the pages written
  long n = 0;
  mach_vm_address_t addr = 0;
  for (;;) {
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj;
    if (mach_vm_region(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt,
                       &obj) != KERN_SUCCESS)
      break;
    if ((info.protection & VM_PROT_WRITE) && !info.shared && size <= ((mach_vm_size_t)1 << 30)) {
      size_t pg = getpagesize(), np = size / pg;
      char *vec = malloc(np);
      if (vec && mincore((void *)addr, size, vec) == 0)
        for (size_t i = 0; i < np; i++)
          if (vec[i] & MINCORE_INCORE) {
            volatile char *q = (volatile char *)(addr + i * pg);
            *q = *q;
            n++;
          }
      free(vec);
    }
    addr += size;
  }
  return n;
}

static void warm_wait(void) {
  const char *qos = getenv("TAU_WARM_QOS");
  int qerr = 0;
  if (qos && !strcmp(qos, "ui")) qerr = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  const char *tm = getenv("TAU_WARM_TOUCH");  // "hot" (default): the last pass's copied pages; "all"; "off"
  if (!tm) tm = "hot";
  long touched = !strcmp(tm, "off") ? 0 : !strcmp(tm, "all") ? pretouch() : pretouch_hot();
  char pp[2048], fifo[2048];
  snprintf(pp, sizeof pp, "%s/ctl-warm-%d", out, getpid());
  snprintf(fifo, sizeof fifo, "%s/fifo-%d", out, getpid());
  is_runner = 0;
  int64_t t_wake;
  if (getenv("TAU_WARM_PIPE")) {
    mkfifo(fifo, 0600);
    int fd = open_nc(fifo, O_RDWR);
    char c;
    for (;;) {
      ssize_t r = read_nc(fd, &c, 1);
      if (r == 1 && access(pp, F_OK) == 0) break;
      if (r <= 0 && errno != EINTR) _exit(0);
    }
    t_wake = now_us();
    close_nc(fd);
    unlink(fifo);
  } else {
    int kq = kqueue();
    struct kevent ev[2];
    signal(SIGUSR1, SIG_IGN);
    EV_SET(&ev[0], SIGUSR1, EVFILT_SIGNAL, EV_ADD, 0, 0, 0);
    int nev = 1;
    if (life_fd >= 0) EV_SET(&ev[nev++], life_fd, EVFILT_READ, EV_ADD, 0, 0, 0);
    kevent(kq, ev, nev, NULL, 0, NULL);
    for (;;) {
      struct kevent got;
      if (kevent(kq, NULL, 0, &got, 1, NULL) <= 0) continue;
      if (got.filter == EVFILT_READ) _exit(0);
      if (got.filter == EVFILT_SIGNAL && access(pp, F_OK) == 0) break;
    }
    t_wake = now_us();
    close(kq);
    signal(SIGUSR1, SIG_DFL);
  }
  long f_wake = minflt_now();
  para_setup(pp);
  para_flt_wake = f_wake;
  uint64_t tid = 0;
  pthread_threadid_np(NULL, &tid);
  msg("B %d %d %d %lld warm %lld qos %d faults %ld %ld touched %ld qerr %d pipe %d tid %llu", getppid(), getpid(), seq,
      (long long)now_us(), (long long)t_wake, (int)qos_class_self(), f_wake, minflt_now(), touched, qerr,
      getenv("TAU_WARM_PIPE") != NULL, (unsigned long long)tid);
}

static void fork_warm(int kq) {
  measure_lock();
  pid_t c = fork();
  if (c < 0) return;
  if (c == 0) {
    close(kq);
    reopen_real_fds();
    warm_wait();
    return;
  }
  warm_pid = c;
  watch_child(kq, c);
  msg("W %d %d", getpid(), c);
}

static void park(int kq) {
  signal(SIGCHLD, SIG_DFL);
  for (;;) {
    struct kevent got;
    int n = kevent(kq, NULL, 0, &got, 1, NULL);
    int st;
    pid_t w;
    while ((w = waitpid(-1, &st, WNOHANG)) > 0)
      if (WIFSIGNALED(st) && WTERMSIG(st) != SIGKILL && WTERMSIG(st) != SIGTERM)
        msg("X %d %d %d", getpid(), w, st);  // a runner crashed: the driver hears of it
    if (n <= 0) continue;
    if (got.filter == EVFILT_READ) _exit(0);  // the driver is gone
    if (got.filter == EVFILT_PROC && (pid_t)got.ident == warm_pid && dense_snap) {  // used: park a new one
      warm_pid = 0;
      int me0 = getpid();
      fork_warm(kq);
      if (getpid() != me0) return;  // (the new warm child, once ordered: a pass)
      continue;
    }
    if (got.filter == EVFILT_SIGNAL) {
      int me = getpid();
      measure_lock();
      char pp[2048];
      snprintf(pp, sizeof pp, "%s/ctl-para-%d", out, me);
      if (access(pp, F_OK) == 0) {  // a paragraph pass first: it is the quick one
        pid_t c = fork();
        if (c == 0) {
          close(kq);
          reopen_real_fds();
          para_setup(pp);
          msg("B %d %d %d %lld", me, getpid(), seq, (long long)now_us());
          return;  // the pass carries on from here
        }
        while (access(pp, F_OK) == 0) usleep(50);  // it has read its orders
      }
      pid_t c = fork();
      if (c == 0) {
        close(kq);
        reopen_real_fds();
        read_ctl(me);
        is_runner = 1;
        last_snap = now_us();
        msg("R %d %d %d %lld", me, getpid(), seq, (long long)now_us());
        return;  // the runner carries on from here
      }
      if (c > 0) watch_child(kq, c);
    }
  }
}

static void snapshot(int dense) {
  int me = getpid();
  measure_lock();
  pid_t c = fork();
  if (c < 0) return;
  if (c == 0) {  // the runner runs on
    reopen_real_fds();
    last_snap = now_us();
    return;
  }
  dense_snap = dense;
  int kq = park_prepare();
  watch_child(kq, c);
  write_extents(me);
  msg("S %d %d %d %lld", me, c, seq, (long long)now_us());
  is_runner = 0;
  if (dense_snap) {
    fork_warm(kq);
    if (getpid() != me) return;  // the warm child, once ordered: a pass, carrying on inside this read()
  }
  park(kq);
}

// A finisher: a grandchild (so nobody waits for it) whose project inputs end now; TeX then stops with
// "no legal \end found" and closes its output as on any fatal error, so the output holds the pages shipped so far.
static void fork_finisher(const char *why) {
  measure_lock();
  pid_t c = fork();
  if (c < 0) return;
  if (c > 0) { waitpid(c, NULL, 0); return; }
  if (fork() != 0) _exit(0);
  reopen_real_fds();  // (the intermediate child's lock state is the parent's: fix_lock applies as is)
  eof_all = 1;
  t_fork = now_us();
  tag = "fin";
  is_runner = 0;
  finish_every = finish_next = 0;
  msg("F %d %d %d %lld %s", getpid(), seq, pages, (long long)now_us(), why);
  const char *smp = getenv("TAU_DEBUG_SAMPLE");  // profile this finisher with sample(1), once per directory
  if (smp && mkdir(smp, 0755) == 0) {
    char pid[16], file[1200];
    snprintf(pid, sizeof pid, "%d", getpid());
    snprintf(file, sizeof file, "%s/sample.txt", smp);
    char *argv[] = {"/usr/bin/sample", pid, "2", "1", "-file", file, NULL};
    pid_t sp;
    posix_spawn(&sp, "/usr/bin/sample", NULL, NULL, argv, environ);
    usleep(500000);
  }
}

// ---------------------------------------------------------------------------------------------------- signals

// ---------------------------------------------------------------------------------------------------- parking

// A parked engine (TAU_PARK=SOCKET, started by `tau-live --park`): its command line reads the main file's name with
// \openin from /.taudot/main.tex, which doesn't name the job as a first \input would. At that lookup (the format
// loaded, kpathsea and the prelude done) it listens on SOCKET; each session that connects sends its environment,
// working directory and pipes, and gets a forked child that carries on as its engine. The name comes from the file
// TAU_MAIN_NAME (set by the session), which /.taudot/main.tex stands for.
static int parked_engine;
static void tau_config(void);
static int recv_all(int c, char *buf, size_t cap, int *fdv, int nfd) {
  struct msghdr m = {0};
  struct iovec io = {buf, cap - 1};
  char cbuf[CMSG_SPACE(sizeof(int) * 4)];
  m.msg_iov = &io, m.msg_iovlen = 1, m.msg_control = cbuf, m.msg_controllen = sizeof cbuf;
  ssize_t n = recvmsg(c, &m, 0);
  if (n <= 0) return -1;
  int got = 0;
  for (struct cmsghdr *h = CMSG_FIRSTHDR(&m); h; h = CMSG_NXTHDR(&m, h))
    if (h->cmsg_level == SOL_SOCKET && h->cmsg_type == SCM_RIGHTS) {
      int k = (int)((h->cmsg_len - CMSG_LEN(0)) / sizeof(int));
      for (int i = 0; i < k && got < nfd; i++) memcpy(&fdv[got++], CMSG_DATA(h) + i * sizeof(int), sizeof(int));
    }
  size_t len = (size_t)n;
  while (len < cap - 1 && !memchr(buf, 0, len)) {  // the rest of the text, up to its NUL
    ssize_t r = read_nc(c, buf + len, cap - 1 - len);
    if (r <= 0) break;
    len += (size_t)r;
  }
  buf[len] = 0;
  return got;
}
static void park_engine(void) {
  const char *sock = getenv("TAU_PARK"), *sig = getenv("TAU_PARK_SIG");
  if (parked_engine || !sock) return;
  parked_engine = 1;
  int ls = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un a = {0};
  a.sun_family = AF_UNIX;
  snprintf(a.sun_path, sizeof a.sun_path, "%s", sock);
  unlink(sock);
  if (ls < 0 || bind(ls, (struct sockaddr *)&a, sizeof a) || listen(ls, 16)) _exit(3);
  signal(SIGCHLD, SIG_IGN);  // (sessions' engines are reaped here; they restore it)
  msg("Z %d %lld", getpid(), (long long)now_us());
  static char req[1 << 16];
  for (;;) {
    struct pollfd pf[2] = {{ls, POLLIN, 0}, {life_fd, POLLIN, 0}};
    if (poll(pf, life_fd >= 0 ? 2 : 1, -1) < 0) continue;
    if (life_fd >= 0 && (pf[1].revents & (POLLIN | POLLHUP))) { unlink(sock); _exit(0); }  // tau-live --park left
    if (!(pf[0].revents & POLLIN)) continue;
    int c = accept(ls, NULL, NULL);
    if (c < 0) continue;
    int fdv[4] = {-1, -1, -1, -1};
    int nf = recv_all(c, req, sizeof req, fdv, 4);
    // the request: "sig SIG\ncwd DIR\nKEY=VALUE\n...", fds: the session's message pipe, lifeline, log
    char *save, *line = strtok_r(req, "\n", &save);
    int ok = nf == 3 && line && !strncmp(line, "sig ", 4) && sig && !strcmp(line + 4, sig);
    pid_t pid = ok ? fork() : -1;
    if (pid == 0) {
      close_nc(ls);
      signal(SIGCHLD, SIG_DFL);
      for (line = strtok_r(NULL, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        char *eq = strchr(line, '=');
        if (!strncmp(line, "cwd ", 4)) { if (chdir(line + 4)) _exit(4); }
        else if (eq) { *eq = 0; setenv(line, eq + 1, 1); }
      }
      if (!getcwd(cwd0, sizeof cwd0)) _exit(4);
      unsetenv("TAU_PARK"), unsetenv("TAU_PARK_SIG");
      if (tau_fd >= 0) close_nc(tau_fd);  // (the parked engine's own: tau-live --park's pipes)
      if (life_fd >= 0) close_nc(life_fd);
      tau_fd = fdv[0], life_fd = fdv[1];
      dup2(fdv[2], 1), dup2(fdv[2], 2);
      close_nc(fdv[2]);
      fcntl_nc(tau_fd, F_SETFD, FD_CLOEXEC), fcntl_nc(life_fd, F_SETFD, FD_CLOEXEC);
      for (int i = 0; i < nfiles; i++) free(files[i]);  // (the zygote's own lookups: of its empty directory)
      nfiles = 0;
      tau_config();
      unsetenv("TAU_FD");
      char b[32];
      int bl = snprintf(b, sizeof b, "%d\n", getpid());
      write_nc(c, b, bl);
      close_nc(c);
      msg("H %d %lld", getpid(), (long long)t0);
      return;  // on with the lookup, as the session's engine
    }
    if (pid < 0) write_nc(c, "0\n", 2);
    close_nc(c);
    for (int i = 0; i < 4; i++) if (fdv[i] >= 0) close_nc(fdv[i]);
  }
}
// /.taudot/main.tex: the file naming the main file (and the park point)
static const char *main_alias(const char *path) {
  if (!path || strcmp(path, "/.taudot/main.tex")) return path;
  park_engine();
  const char *m = getenv("TAU_MAIN_NAME");
  if (getenv("TAU_ALIAS_DEBUG")) {
    char b[1200];
    int n = snprintf(b, sizeof b, "tau: alias %s -> %s (pid %d)\n", path, m ? m : "(none)", getpid());
    write_nc(2, b, n);
  }
  return m ? m : path;
}

static int magic(const char *path) {  // 1 if PATH is a TeX-side signal (handled here)
  if (!path || strncmp(path, "/.taudot/", 9)) return 0;
  const char *w = path + 9;
  if (!strncmp(w, "ship", 4)) {
    int n = atoi(w + 5);  // /.taudot/ship/N: N shipouts so far (one lookup is several calls)
    if (n <= pages) return 1;
    pages = n;
    msg("p %d %d %d %lld", getpid(), seq, pages, (long long)now_us());
    int g = finish_rule ? goal_page() : -1;
    int at_goal = g >= 0 && pages == g + 1;  // the goal page itself: at once
    int rule = finish_rule && (at_goal || now_us() - last_finish >= finish_period_us);
    if (tau_fd >= 0 && is_runner && passed && (finish_every || finish_next || rule)) {
      finish_next = 0;
      last_finish = now_us();
      fork_finisher("ship");
    }
  } else if (!strncmp(w, "t/", 2)) {
    int k = atoi(w + 2);
    if (k >= 0 && k < 8 && !t_mark[k]) t_mark[k] = now_us();
  } else if (!strncmp(w, "stop", 4)) {
    if (para_stop) {  // the pass's page(s): the bytes the engine appended to its output since the pass began
      int64_t t_stop = now_us();
      fflush(NULL);
      int64_t t_flushed = now_us();
      char p[2048];
      snprintf(p, sizeof p, "%s/para-%d-%d.bin", out, seq, getpid());
      int fd = open_nc(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
      if (fd >= 0 && para_out && para_out->len > para_base) write_nc(fd, para_out->data + para_base, para_out->len - para_base);
      if (fd >= 0) close_nc(fd);
      const char *dash = w[4] == '/' ? strchr(w + 5, '-') : NULL;  // stop/LINES-PIECES-OWN(.tex)
      const char *dash2 = dash ? strchr(dash + 1, '-') : NULL;
      // -gBASExSPANxHT: the lines' geometry (sp), when the pass took its own lines off the page
      const char *g = dash2 ? strstr(dash2, "-g") : NULL;
      long gb = 0, gs = 0, gh = 0;
      int geo = 0;
      if (g) {
        char *q;
        gb = strtol(g + 2, &q, 10);
        if (*q == 'x') { gs = strtol(q + 1, &q, 10); if (*q == 'x') { gh = strtol(q + 1, &q, 10); geo = 1; } }
      }
      msg("Q %d %d %d %d %lld %s %lld %lld %zu own %d geo %d %ld %ld %ld", getpid(), seq, w[4] == '/' ? atoi(w + 5) : 0,
          dash ? atoi(dash + 1) : 0, (long long)now_us(), p,
          (long long)t_para_start, (long long)t_para_flush, para_out ? para_out->len - para_base : 0,
          dash2 ? atoi(dash2 + 1) : 1, geo, gb, gs, gh);
      {  // the pages this pass copied (written after the fork): the next warm pass pre-touches just these
        char hp[2048], tmp[2100];
        snprintf(hp, sizeof hp, "%s/hot", out);
        snprintf(tmp, sizeof tmp, "%s.%d", hp, getpid());
        struct stat hst;  // at most every 5 s: the walk costs several ms of CPU (after the lines are out)
        int fresh = stat(hp, &hst) == 0 && time(NULL) - hst.st_mtime < 5;
        int hf = fresh ? -1 : open_nc(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        mach_vm_address_t addr = 0;
        size_t pg = getpagesize();
        while (hf >= 0) {
          mach_vm_size_t size = 0;
          vm_region_basic_info_data_64_t info;
          mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
          mach_port_t obj;
          if (mach_vm_region(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt,
                             &obj) != KERN_SUCCESS)
            break;
          if ((info.protection & VM_PROT_WRITE) && !info.shared && size <= ((mach_vm_size_t)1 << 30)) {
            size_t np = size / pg;
            char *vec = malloc(np);
            if (vec && mincore((void *)addr, size, vec) == 0)
              for (size_t i = 0; i < np; i++)
                if (vec[i] & MINCORE_COPIED) {
                  uint64_t a = addr + i * pg;
                  write_nc(hf, &a, sizeof a);
                }
            free(vec);
          }
          addr += size;
        }
        if (hf >= 0) { close_nc(hf); rename(tmp, hp); }
      }
      if (para_flt_wake >= 0) {
        struct rusage ru;
        getrusage(RUSAGE_SELF, &ru);
        msg("q %d %d faults_from_wake %ld marks %lld %lld %lld %lld %lld %lld", getpid(), seq, ru.ru_minflt - para_flt_wake,
            (long long)t_mark[0], (long long)t_mark[1], (long long)t_mark[2], (long long)t_mark[3], (long long)t_stop,
            (long long)t_flushed);
        msg("m %d %d %lld %lld %lld", getpid(), seq, (long long)t_mark[4], (long long)t_mark[5], (long long)t_mark[6]);
      }
      if (getenv("TAU_DEBUG")) dump_outputs(0);
      _exit(0);
    }
  }
  return 1;
}

// ---------------------------------------------------------------------------------------------------- outputs

static void mkdirs(const char *dir) {
  char b[2048];
  snprintf(b, sizeof b, "%s", dir);
  for (char *p = b + 1; *p; p++)
    if (*p == '/') { *p = 0; mkdir(b, 0755); *p = '/'; }
  mkdir(b, 0755);
}

static int is_output(const mfile *f) {  // the typeset document: written first, announced at once
  const char *d = strrchr(f->rel, '.');
  return d && (!strcmp(d, ".pdf") || !strcmp(d, ".xdv") || !strcmp(d, ".dvi"));
}

static void dump_file(const char *dir, mfile *f) {
  char p[4096];
  snprintf(p, sizeof p, "%s/%s", dir, f->rel);
  char *sl = strrchr(p, '/');
  *sl = 0;
  mkdirs(p);
  *sl = '/';
  int fd = open_nc(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;
  size_t done = 0;
  while (done < f->len) {
    ssize_t w = write_nc(fd, f->data + done, f->len - done);
    if (w <= 0) break;
    done += w;
  }
  close_nc(fd);
}

// Outputs go to TAU_OUT/<tag>-<seq>-<pid>/: the document first, then E (the driver may take it), then the rest.
static void dump_outputs(int announce) {
  if (!out[0]) return;
  char dir[2048];
  snprintf(dir, sizeof dir, "%s/%s-%d-%d", out, tag, seq, getpid());
  mkdirs(dir);
  for (int pass = 0; pass < 2; pass++) {
    for (int i = 0; i < nfiles; i++)  // pass 0: the document and its SyncTeX
      if (files[i]->written && (is_output(files[i]) || strstr(files[i]->rel, ".synctex")) == !pass)
        dump_file(dir, files[i]);
    if (pass == 0 && !strcmp(tag, "fin")) {  // a finisher: its log and .aux are of no use
      if (announce) {
      {
        struct rusage ru;
        getrusage(RUSAGE_SELF, &ru);
        msg("Z %d %lld %lld %lld cpu %ld faults %ld", getpid(), (long long)t_fork, (long long)t_inject,
            (long long)now_us(), (long)(ru.ru_utime.tv_sec * 1000000 + ru.ru_utime.tv_usec + ru.ru_stime.tv_sec * 1000000 + ru.ru_stime.tv_usec),
            ru.ru_minflt);
      }
        msg("E %d %d %d %lld %s %d", getpid(), seq, pages, (long long)now_us(), tag, exit_code);
      }
      return;
    }
  }
  if (tau_fd >= 0) write_extents(getpid());  // for the driver's latexmk rule
  if (announce) msg("E %d %d %d %lld %s %d", getpid(), seq, pages, (long long)now_us(), tag, exit_code);
}

static void my_exit(int code) {
  exit_code = code;
  exit(code);
}
INTERPOSE(my_exit, exit);

static void at_exit(void) {
  if (!inited) return;
  fflush(NULL);
  dump_outputs(1);
  if (!strcmp(tag, "fin")) _exit(0);  // skip the teardown: nobody waits for it
}

// ---------------------------------------------------------------------------------------------------- TeX Live

#include "store.c"

// Which paths may be fetched: only those the tree's ls-R files list (the image's whole file list; kpathsea's probes
// of other directories and names TeX Live doesn't have never reach the network), less the ones that failed before.
// Read at the first miss and kept for the process (snapshots inherit it). Misses that aren't the network's are
// remembered across sessions in TREE/.taudot-fetch-misses (one path per line, relative to the tree).
static uint64_t *ls_set;  // open addressing over 64-bit hashes of tree-relative paths (0: empty)
static size_t ls_cap;
static int ls_state;  // 0 not read, 1 read, -1 no ls-R (only the boot files may be fetched)
static uint64_t ls_hash(const char *s, size_t n) {
  uint64_t h = 1469598103934665603ull;
  for (size_t i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * 1099511628211ull;
  return h ? h : 1;
}
static void ls_add(const char *s, size_t n) {
  uint64_t h = ls_hash(s, n);
  for (size_t i = h & (ls_cap - 1);; i = (i + 1) & (ls_cap - 1)) {
    if (ls_set[i] == h) return;
    if (!ls_set[i]) { ls_set[i] = h; return; }
  }
}
static int ls_has(const char *s) {
  if (!ls_set) return 0;
  uint64_t h = ls_hash(s, strlen(s));
  for (size_t i = h & (ls_cap - 1); ls_set[i]; i = (i + 1) & (ls_cap - 1))
    if (ls_set[i] == h) return 1;
  return 0;
}
static char *ls_slurp(const char *p, size_t *n) {
  int fd = open(p, O_RDONLY);
  if (fd < 0) return NULL;
  struct stat s;
  if (fstat(fd, &s)) { close(fd); return NULL; }
  char *b = malloc(s.st_size + 1);
  size_t k = 0;
  while (k < (size_t)s.st_size) {
    ssize_t r = read(fd, b + k, s.st_size - k);
    if (r <= 0) break;
    k += r;
  }
  close(fd);
  b[k] = 0;
  *n = k;
  return b;
}
static void ls_misses_path(char *p, size_t cap) { snprintf(p, cap, "%s.taudot-fetch-misses", tlroot); }
static void ls_load(void) {
  if (ls_state) return;
  ls_state = -1;
  free(ls_set), ls_set = NULL;
  static const char *trees[] = {"texmf-dist", "texmf-var", "texmf-local", "texmf-config", NULL};
  char *buf[4] = {0};
  size_t len[4] = {0}, lines = 0;
  for (int t = 0; trees[t]; t++) {
    char p[2048];
    snprintf(p, sizeof p, "%s%s/ls-R", tlroot, trees[t]);
    buf[t] = ls_slurp(p, &len[t]);
    for (size_t i = 0; buf[t] && i < len[t]; i++) lines += buf[t][i] == '\n';
  }
  if (!lines) return;
  for (ls_cap = 1024; ls_cap < 2 * lines + 64; ls_cap *= 2) {}
  ls_set = calloc(ls_cap, sizeof *ls_set);
  for (int t = 0; trees[t]; t++) {
    if (!buf[t]) continue;
    char path[2048];
    size_t tl = strlen(trees[t]), dl = 0;  // path = TREE/DIR/ (dir from the last "DIR:" line)
    memcpy(path, trees[t], tl);
    path[tl] = '/';
    dl = tl + 1;
    for (char *l = buf[t], *e; l < buf[t] + len[t]; l = e + 1) {
      e = memchr(l, '\n', buf[t] + len[t] - l);
      if (!e) e = buf[t] + len[t];
      size_t n = e - l;
      if (!n || l[0] == '%') continue;
      if (l[n - 1] == ':') {  // a directory: "./tex/latex/base:" or "/abs/.../tex/latex/base:"
        const char *d = l;
        size_t dn = n - 1;
        if (dn >= 2 && d[0] == '.' && d[1] == '/') d += 2, dn -= 2;
        else if (dn == 1 && d[0] == '.') dn = 0;
        if (tl + 1 + dn + 1 >= sizeof path) continue;
        memcpy(path + tl + 1, d, dn);
        dl = tl + 1 + dn;
        if (dn) path[dl++] = '/';
        continue;
      }
      if (dl + n >= sizeof path) continue;
      memcpy(path + dl, l, n);
      ls_add(path, dl + n);
    }
    free(buf[t]);
  }
  // misses kept from earlier sessions: not listed any more
  char mp[2048];
  ls_misses_path(mp, sizeof mp);
  size_t mn;
  char *m = ls_slurp(mp, &mn);
  for (char *l = m, *e; m && l < m + mn; l = e + 1) {
    e = memchr(l, '\n', m + mn - l);
    if (!e) e = m + mn;
    uint64_t h = ls_hash(l, e - l);
    for (size_t i = h & (ls_cap - 1); ls_set[i]; i = (i + 1) & (ls_cap - 1))
      if (ls_set[i] == h) { ls_set[i] = 2; break; }  // (2: a tombstone no path hashes to... almost: harmless)
  }
  free(m);
  ls_state = 1;
}
static void ls_forget(const char *rel) {  // a listed path that couldn't be had (not the network's fault)
  char mp[2048], line[2100];
  ls_misses_path(mp, sizeof mp);
  int fd = open(mp, O_WRONLY | O_CREAT | O_APPEND, 0644);
  int l = snprintf(line, sizeof line, "%s\n", rel);
  if (fd >= 0) { write(fd, line, l); close(fd); }
  uint64_t h = ls_hash(rel, strlen(rel));
  for (size_t i = h & (ls_cap - 1); ls_set && ls_set[i]; i = (i + 1) & (ls_cap - 1))
    if (ls_set[i] == h) { ls_set[i] = 2; break; }
}
static int ls_boot(const char *rel) {  // what a tree needs before its ls-R can be read
  return !strcmp(rel, "texmf-dist/ls-R") || !strcmp(rel, "texmf-var/ls-R") || !strcmp(rel, "texmf-dist/web2c/texmf.cnf");
}

// A lookup missed under the TeX Live tree: fetch PATH once if ls-R lists it, from the store in this process
// (TEXSTORE_URL, store.c), or by the program TAU_FETCH when that is set (a stand-in client); 1 if it is there now.
static int tl_fetch(const char *path) {
  const char *url = getenv("TEXSTORE_URL");
  int native = !fetch_cmd && url && *url;
  if ((!fetch_cmd && !native) || !tlroot[0] || strncmp(path, tlroot, strlen(tlroot))) return 0;
  const char *rel = path + strlen(tlroot);
  if (!ls_boot(rel)) {
    ls_load();
    if (ls_state < 0 || !ls_has(rel)) return 0;  // not in this TeX Live: no fetch
  }
  for (int i = 0; i < nfailed; i++)
    if (!strcmp(fetch_failed[i], path)) return 0;
  if (tau_fd >= 0) msg("G %s", rel);  // the driver's fetch event
  int offline = 0;
  if (native) {
    if (store_fetch(path)) {
      if (ls_boot(rel)) ls_state = 0;  // (a new ls-R: read it again at the next miss)
      return 1;
    }
    offline = st_offline;
    if (offline && tau_fd >= 0) msg("g offline %s", rel);  // the driver's error event
  } else {
    char *argv[] = {"/bin/sh", "-c", "exec $TAU_FETCH \"$1\" </dev/null >/dev/null 2>&1", "sh", (char *)path, NULL};
    pid_t pid;
    int st = 1;
    if (posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ) == 0) waitpid(pid, &st, 0);
    if (st == 0) {
      if (ls_boot(rel)) ls_state = 0;
      return 1;
    }
  }
  if (native && !offline && !ls_boot(rel)) ls_forget(rel);  // (TAU_FETCH can't say why it failed)
  fetch_failed = realloc(fetch_failed, (nfailed + 1) * sizeof *fetch_failed);
  fetch_failed[nfailed++] = strdup(path);
  return 0;
}

// ---------------------------------------------------------------------------------------------------- init

// What a process takes from its environment (again in a parked engine's child: park())
static void tau_config(void) {
  const char *p = getenv("TAU_PROJECT");
  if (!p) p = cwd0;
  if (!realpath(p, proj)) snprintf(proj, sizeof proj, "%s", p);
  projlen = strlen(proj);
  const char *o = getenv("TAU_OUT");
  snprintf(out, sizeof out, "%s", o ? o : "");
  const char *s = getenv("TAU_FD");
  if (s) tau_fd = atoi(s);
  s = getenv("TAU_LIFE");
  if (s) life_fd = atoi(s);
  s = getenv("TAU_SNAPSHOT_MS");
  if (s) snap_us = (long)(atof(s) * 1000);
  s = getenv("TAU_MARK");  // "REL LO HI"
  if (s && sscanf(s, "%1023s %ld %ld", mark_rel, &mark_lo, &mark_hi) != 3) mark_lo = mark_hi = -1;
  s = getenv("TAU_FINISH_TEXT");
  if (s) finish_text = s;
  s = getenv("TAU_FINISH");
  if (s && !strcmp(s, "every")) finish_every = 1;
  s = getenv("TAU_WARM_QOS");  // only an exec'd process may set its QoS (EPERM after fork); children inherit it
  if (s && !strcmp(s, "ui")) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  s = getenv("TAU_TLROOT");
  if (!s || !*s) s = getenv("TEXSTORE_ROOT");  // (the app's name for the tree)
  if (s && *s) snprintf(tlroot, sizeof tlroot, "%s/", s);
  fetch_cmd = getenv("TAU_FETCH");
  t0 = last_snap = now_us();
}

__attribute__((constructor)) static void tau_init(void) {
  if (!getcwd(cwd0, sizeof cwd0)) return;
  tau_config();
  // children (xdvipdfmx, bibtex, kpsewhich) must not inherit us
  unsetenv("DYLD_INSERT_LIBRARIES");
  unsetenv("TAU_FD");
  atexit(at_exit);
  signal(SIGUSR2, on_usr2);
  inited = 1;
  if (tau_fd >= 0) {
    fcntl_nc(tau_fd, F_SETFD, FD_CLOEXEC);
    if (life_fd >= 0) fcntl_nc(life_fd, F_SETFD, FD_CLOEXEC);
    msg("H %d %lld", getpid(), (long long)t0);
  }
}

// ---------------------------------------------------------------------------------------------------- calls

static int reserve_fd(void) { return open_nc("/dev/null", O_RDONLY | O_CLOEXEC); }

static int alias_fd = -1;
static int do_open_(const char *path, int flags, int mode, int (*real)(const char *, int, ...));
static int do_open(const char *path, int flags, int mode, int (*real)(const char *, int, ...)) {
  const char *p2 = main_alias(path);
  int fd = do_open_(p2, flags, mode, real);
  if (p2 != path) {
    alias_fd = fd;
    if (getenv("TAU_ALIAS_DEBUG")) {
      char b[1300];
      int k = snprintf(b, sizeof b, "tau: open alias -> fd %d errno %d used %d rel %s\n", fd, errno, fd >= 0 && fd < MAXFD ? fds[fd].used : -1, fd >= 0 && fd < MAXFD && fds[fd].used ? fds[fd].f->rel : "-");
      write_nc(2, b, k);
    }
  }
  return fd;
}
static int do_open_(const char *path, int flags, int mode, int (*real)(const char *, int, ...)) {
  char buf[2048];
  if (magic(path)) { errno = ENOENT; return -1; }
  const char *rel = project_rel(path, buf, sizeof buf);
  if (!rel) {
    int fd = real(path, flags, mode);
    if (fd < 0 && errno == ENOENT && tl_fetch(path)) fd = real(path, flags, mode);
    if (fd >= 0 && (flags & O_ACCMODE) == O_RDONLY && !(flags & O_DIRECTORY)) {
      struct stat st;
      if (!fstat(fd, &st) && S_ISREG(st.st_mode)) {
        if (nrfds == caprfds) {
          caprfds = caprfds ? caprfds * 2 : 64;
          rfds = realloc(rfds, caprfds * sizeof *rfds);
        }
        int i;
        for (i = 0; i < nrfds && rfds[i].fd != fd; i++) {}
        if (i == nrfds) nrfds++;
        else free(rfds[i].path);
        rfds[i] = (rfd){fd, flags, strdup(path)};
      }
    }
    return fd;
  }
  int acc = flags & O_ACCMODE;
  mfile *f;
  if (acc == O_RDONLY) {
    f = get_file(rel, 0);
    if (!f->data && !f->written) {
      f->missing = 1;
      if (f->extent < 1) f->extent = 1;  // a miss counts as "seen empty": creating it invalidates
      errno = ENOENT;
      return -1;
    }
  } else {
    f = get_file(rel, 1);
    if (!f->written || (flags & O_TRUNC)) {
      if (!f->written && !(flags & O_TRUNC) && !f->data) load_disk(f);
      if (flags & O_TRUNC) f->len = 0;
      f->written = 1;
      f->missing = 0;
    }
  }
  int fd = reserve_fd();
  if (fd < 0) return -1;
  if (fd >= MAXFD) { close_nc(fd); errno = EMFILE; return -1; }
  fds[fd] = (mfd){1, f, (flags & O_APPEND) ? f->len : 0, acc != O_RDONLY, 0};
  return fd;
}

static int my_open(const char *path, int flags, ...) {
  va_list a;
  va_start(a, flags);
  int mode = (flags & O_CREAT) ? va_arg(a, int) : 0;
  va_end(a);
  return do_open(path, flags, mode, open);
}
INTERPOSE(my_open, open);
static int my_open_nc(const char *path, int flags, ...) {
  va_list a;
  va_start(a, flags);
  int mode = (flags & O_CREAT) ? va_arg(a, int) : 0;
  va_end(a);
  return do_open(path, flags, mode, open_nc);
}
INTERPOSE(my_open_nc, open_nc);

static int my_openat(int dfd, const char *path, int flags, ...) {
  va_list a;
  va_start(a, flags);
  int mode = (flags & O_CREAT) ? va_arg(a, int) : 0;
  va_end(a);
  if (dfd == AT_FDCWD || (path && path[0] == '/')) return do_open(path, flags, mode, open);
  return openat(dfd, path, flags, mode);
}
INTERPOSE(my_openat, openat);
static int my_openat_nc(int dfd, const char *path, int flags, ...) {
  va_list a;
  va_start(a, flags);
  int mode = (flags & O_CREAT) ? va_arg(a, int) : 0;
  va_end(a);
  if (dfd == AT_FDCWD || (path && path[0] == '/')) return do_open(path, flags, mode, open_nc);
  return openat_nc(dfd, path, flags, mode);
}
INTERPOSE(my_openat_nc, openat_nc);

static int do_close(int fd, int (*real)(int)) {
  if (fd >= 0 && fd < MAXFD && fds[fd].used) fds[fd].used = 0;
  for (int i = 0; i < nrfds; i++)
    if (rfds[i].fd == fd) {
      free(rfds[i].path);
      rfds[i] = rfds[--nrfds];
      break;
    }
  return real(fd);
}
static int my_close(int fd) { return do_close(fd, close); }
INTERPOSE(my_close, close);
static int my_close_nc(int fd) { return do_close(fd, close_nc); }
INTERPOSE(my_close_nc, close_nc);

static ssize_t mem_read(mfd *d, void *buf, size_t n, int fd) {
  mfile *f = d->f;
  int text = !f->binary && !f->written;
  if (text && !d->wr) {
    int dense = dense_lo >= 0 && !strcmp(f->rel, dense_rel) && (long)d->pos >= dense_lo && (long)d->pos < dense_hi;
    int mark = mark_lo >= 0 && (long)d->pos >= mark_lo && (long)d->pos < mark_hi && !strcmp(f->rel, mark_rel);
    if (tau_fd >= 0 && is_runner && !eof_all && (dense || mark || now_us() - last_snap >= snap_us)) {
      reading_fd = fd;
      snprintf(snap_rel, sizeof snap_rel, "%s", f->rel);
      snap_pos = (long)d->pos;
      snapshot(dense);
      reading_fd = -1;
      d = &fds[fd];
      f = d->f;
    }
    if (para_mode && f != para_file) {
      note_extent(f, (long)d->pos + 1);
      return 0;
    }
    if (eof_all) {
      size_t fl = strlen(finish_text);
      if (!t_inject) t_inject = now_us();
      if (d->fin_off < fl) {  // once per open file: a verbatim reader may swallow it; the file below then ends
        size_t k = fl - d->fin_off < n ? fl - d->fin_off : n;
        memcpy(buf, finish_text + d->fin_off, k);
        d->fin_off += k;
        return (ssize_t)k;
      }
      note_extent(f, (long)d->pos + 1);
      return 0;
    }
  }
  if (para_mode && f == para_file && !t_para_flush && d->pos >= para_end) t_para_flush = now_us();
  if (finish_asap && is_runner && tau_fd >= 0 && passed) {
    finish_asap = 0;
    reading_fd = fd;
    fork_finisher("asked");
    reading_fd = -1;
    d = &fds[fd];
    f = d->f;
  }
  if (d->pos >= f->len) {
    note_extent(f, (long)f->len + 1);
    return 0;
  }
  size_t k = f->len - d->pos;
  if (k > n) k = n;
  if (text) {
    char *nl = memchr(f->data + d->pos, '\n', k);
    if (nl) k = nl - (f->data + d->pos) + 1;
  }
  memcpy(buf, f->data + d->pos, k);
  d->pos += k;
  note_extent(f, (long)d->pos);
  return (ssize_t)k;
}

static ssize_t my_read(int fd, void *buf, size_t n) {
  if (getenv("TAU_ALIAS_DEBUG") && parked_engine) {
    char b[200];
    int k = snprintf(b, sizeof b, "tau: read alias fd %d used %d\n", fd, fd < MAXFD ? fds[fd].used : -1);
    write_nc(2, b, k);
  }
  if (fd >= 0 && fd < MAXFD && fds[fd].used) return mem_read(&fds[fd], buf, n, fd);
  return read(fd, buf, n);
}
INTERPOSE(my_read, read);
static ssize_t my_read_nc(int fd, void *buf, size_t n) {
  ssize_t r = fd >= 0 && fd < MAXFD && fds[fd].used ? mem_read(&fds[fd], buf, n, fd) : read_nc(fd, buf, n);
  if (getenv("TAU_ALIAS_DEBUG") && parked_engine) {
    char b[200];
    int k = snprintf(b, sizeof b, "tau: read_nc fd %d used %d -> %zd (eof_all %d para %d)\n", fd,
                     fd >= 0 && fd < MAXFD ? fds[fd].used : -1, r, eof_all, para_mode);
    write_nc(2, b, k);
  }
  return r;
}
INTERPOSE(my_read_nc, read_nc);

static ssize_t mem_pread(mfd *d, void *buf, size_t n, off_t off) {
  mfile *f = d->f;
  if ((size_t)off >= f->len) return 0;
  size_t k = f->len - off;
  if (k > n) k = n;
  memcpy(buf, f->data + off, k);
  note_extent(f, (long)(off + k));
  return (ssize_t)k;
}
static ssize_t my_pread(int fd, void *buf, size_t n, off_t off) {
  if (fd >= 0 && fd < MAXFD && fds[fd].used) return mem_pread(&fds[fd], buf, n, off);
  return pread(fd, buf, n, off);
}
INTERPOSE(my_pread, pread);
static ssize_t my_pread_nc(int fd, void *buf, size_t n, off_t off) {
  if (fd >= 0 && fd < MAXFD && fds[fd].used) return mem_pread(&fds[fd], buf, n, off);
  return pread_nc(fd, buf, n, off);
}
INTERPOSE(my_pread_nc, pread_nc);

static ssize_t mem_write(mfd *d, const void *buf, size_t n) {
  mfile *f = d->f;
  if (!d->wr) { errno = EBADF; return -1; }
  size_t end = d->pos + n;
  if (end + 1 > f->cap) {
    if (!f->mapped && end + 1 > (1 << 20) && end + 1 <= RESERVE) {  // big outputs (the PDF): reserve once
      char *m = mmap(NULL, RESERVE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
      if (m != MAP_FAILED) {
        if (f->len) memcpy(m, f->data, f->len);
        free(f->data);
        f->data = m, f->cap = RESERVE, f->mapped = 1;
      }
    }
    if (end + 1 > f->cap) {
      if (f->mapped) { errno = EFBIG; return -1; }
      size_t c = f->cap ? f->cap : 65536;
      while (c < end + 1) c *= 2;
      f->data = realloc(f->data, c);
      f->cap = c;
    }
  }
  if (d->pos > f->len) memset(f->data + f->len, 0, d->pos - f->len);
  memcpy(f->data + d->pos, buf, n);
  d->pos = end;
  if (end > f->len) f->len = end;
  return (ssize_t)n;
}
static ssize_t my_write(int fd, const void *buf, size_t n) {
  if (fd >= 0 && fd < MAXFD && fds[fd].used) return mem_write(&fds[fd], buf, n);
  return write(fd, buf, n);
}
INTERPOSE(my_write, write);
static ssize_t my_write_nc(int fd, const void *buf, size_t n) {
  if (fd >= 0 && fd < MAXFD && fds[fd].used) return mem_write(&fds[fd], buf, n);
  return write_nc(fd, buf, n);
}
INTERPOSE(my_write_nc, write_nc);

static off_t my_lseek(int fd, off_t off, int whence) {
  if (fd >= 0 && fd < MAXFD && fds[fd].used) {
    mfd *d = &fds[fd];
    off_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? (off_t)d->pos : (off_t)d->f->len;
    if (base + off < 0) { errno = EINVAL; return -1; }
    d->pos = base + off;
    return d->pos;
  }
  return lseek(fd, off, whence);
}
INTERPOSE(my_lseek, lseek);

static void fake_stat(mfile *f, struct stat *st) {
  memset(st, 0, sizeof *st);
  st->st_mode = S_IFREG | 0644;
  st->st_nlink = 1;
  st->st_size = f->len;
  st->st_blksize = 4096;
  st->st_uid = getuid();
  st->st_gid = getgid();
  st->st_ino = (ino_t)(uintptr_t)f;
  // fixed times: \pdffilemoddate and friends must not see the clock
  st->st_mtimespec.tv_sec = st->st_ctimespec.tv_sec = st->st_atimespec.tv_sec = 1700000000;
}

static int my_fstat(int fd, struct stat *st) {
  if (fd >= 0 && fd < MAXFD && fds[fd].used) { fake_stat(fds[fd].f, st); return 0; }
  return fstat(fd, st);
}
INTERPOSE(my_fstat, fstat);

// Lookups of project files: answered from memory (a written file exists; a file read before has its loaded size).
static int path_stat(const char *path, struct stat *st, int (*real)(const char *, struct stat *)) {
  char buf[2048];
  path = main_alias(path);
  if (magic(path)) { errno = ENOENT; return -1; }
  const char *rel = project_rel(path, buf, sizeof buf);
  if (rel) {
    mfile *f = find_file(rel);
    if (f && (f->written || f->data)) { fake_stat(f, st); return 0; }
    if (f && f->missing) { errno = ENOENT; return -1; }
    int r = real(path, st);
    if (r == 0 && S_ISREG(st->st_mode)) {
      f = get_file(rel, 0);
      if (f->data) { fake_stat(f, st); return 0; }
    }
    if (r != 0) {
      f = get_file(rel, 0);  // loads nothing; recorded as a miss
      f->missing = 1;
      if (f->extent < 1) f->extent = 1;
    }
    return r;
  }
  int r = real(path, st);
  if (r != 0 && errno == ENOENT && tl_fetch(path)) r = real(path, st);
  return r;
}
static int my_stat(const char *path, struct stat *st) { return path_stat(path, st, stat); }
INTERPOSE(my_stat, stat);
static int my_lstat(const char *path, struct stat *st) { return path_stat(path, st, lstat); }
INTERPOSE(my_lstat, lstat);

static int my_access(const char *path, int mode) {
  char buf[2048];
  path = main_alias(path);
  if (magic(path)) { errno = ENOENT; return -1; }
  const char *rel = project_rel(path, buf, sizeof buf);
  if (rel) {
    struct stat st;
    if (path_stat(path, &st, stat) == 0) return 0;
    return -1;
  }
  int r = access(path, mode);
  if (r != 0 && errno == ENOENT && tl_fetch(path)) r = access(path, mode);
  return r;
}
INTERPOSE(my_access, access);

static int my_fcntl(int fd, int cmd, ...) {
  va_list a;
  va_start(a, cmd);
  long arg = va_arg(a, long);
  va_end(a);
  if (fd >= 0 && fd < MAXFD && fds[fd].used && cmd == F_GETFL) return fds[fd].wr ? O_RDWR : O_RDONLY;
  return fcntl(fd, cmd, arg);
}
INTERPOSE(my_fcntl, fcntl);

static int my_fsync(int fd) {
  if (fd >= 0 && fd < MAXFD && fds[fd].used) return 0;
  return fsync(fd);
}
INTERPOSE(my_fsync, fsync);

static int my_ftruncate(int fd, off_t len) {
  if (fd >= 0 && fd < MAXFD && fds[fd].used) {
    mfile *f = fds[fd].f;
    if ((size_t)len <= f->len) f->len = len;
    else {
      mfd *d = &fds[fd];
      size_t p = d->pos;
      d->pos = f->len;
      char z[4096] = {0};
      while (f->len < (size_t)len) mem_write(d, z, (size_t)len - f->len < sizeof z ? (size_t)len - f->len : sizeof z);
      d->pos = p;
    }
    return 0;
  }
  return ftruncate(fd, len);
}
INTERPOSE(my_ftruncate, ftruncate);

static int my_unlink(const char *path) {  // LaTeX doesn't, but tools do: forget a written file
  char buf[2048];
  const char *rel = project_rel(path, buf, sizeof buf);
  if (rel) {
    mfile *f = find_file(rel);
    if (f) { f->written = 0; free_data(f); f->missing = 1; }
    return 0;
  }
  return unlink(path);
}
INTERPOSE(my_unlink, unlink);

static int my_rename(const char *a, const char *b) {
  char ba[2048], bb[2048];
  const char *ra = project_rel(a, ba, sizeof ba), *rb = project_rel(b, bb, sizeof bb);
  if (ra && rb) {
    mfile *fa = find_file(ra);
    if (!fa || !fa->written) { errno = ENOENT; return -1; }
    mfile *fb = get_file(rb, 1);
    free_data(fb);
    fb->data = fa->data, fb->len = fa->len, fb->cap = fa->cap, fb->mapped = fa->mapped, fb->written = 1,
    fb->missing = 0;
    fa->data = NULL, fa->len = fa->cap = 0, fa->mapped = 0, fa->written = 0, fa->missing = 1;
    return 0;
  }
  return rename(a, b);
}
INTERPOSE(my_rename, rename);

// ---------------------------------------------------------------------------------------------------- streams

static FILE *my_fopen(const char *path, const char *mode) {
  FILE *f = fopen(path, mode);
  if (f && f->_file >= 0 && f->_file < MAXFD) stream_of[f->_file] = f;
  return f;
}
INTERPOSE(my_fopen, fopen);
extern FILE *fopen_ext(const char *, const char *) __asm("_fopen$DARWIN_EXTSN");
static FILE *my_fopen_ext(const char *path, const char *mode) {
  FILE *f = fopen_ext(path, mode);
  if (f && f->_file >= 0 && f->_file < MAXFD) stream_of[f->_file] = f;
  return f;
}
INTERPOSE(my_fopen_ext, fopen_ext);
static FILE *my_freopen(const char *path, const char *mode, FILE *old) {
  FILE *f = freopen(path, mode, old);
  if (f && f->_file >= 0 && f->_file < MAXFD) stream_of[f->_file] = f;
  return f;
}
INTERPOSE(my_freopen, freopen);
static FILE *my_fdopen(int fd, const char *mode) {
  FILE *f = fdopen(fd, mode);
  if (f && fd >= 0 && fd < MAXFD) stream_of[fd] = f;
  return f;
}
INTERPOSE(my_fdopen, fdopen);
static int my_fclose(FILE *f) {
  int fd = f->_file;
  if (fd >= 0 && fd < MAXFD && stream_of[fd] == f) stream_of[fd] = NULL;
  return fclose(f);
}
INTERPOSE(my_fclose, fclose);
