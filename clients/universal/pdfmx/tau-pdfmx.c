/* MIT. tau-pdfmx: xdvipdfmx kept resident, so converting a page costs the page, not kpathsea's start.
 *
 * Linked with TeX Live's dvipdfm-x objects, unmodified (dvipdfmx.c is compiled with main renamed): the program as a
 * whole is therefore GPL, a separate program like the engines. This file stays MIT.
 *
 *   tau-pdfmx ARGS...       one conversion, exactly `xdvipdfmx ARGS...` (for checks)
 *   tau-pdfmx serve         one request per line on stdin: `DIR<TAB>ARG<TAB>ARG...` (DIR: the working directory of
 *                           the conversion, as the engine's); one answer per request on stdout:
 *                           `done CODE US` (CODE: xdvipdfmx's exit status, US: microseconds from request to answer)
 *
 * Most of a one-page xdvipdfmx run is kpathsea reading the tree's ls-R files into its hash (~80% on a 48-page paper).
 * The server does that once, then forks a child per request that runs xdvipdfmx's main with the request's arguments:
 * every request starts from the same warm state, so the output is what a fresh `xdvipdfmx` gives, byte for byte.
 * A child is forked ahead of each request and parked, so the fork's cost is off the request's path too.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <kpathsea/kpathsea.h>

int dvipdfmx_stock_main(int argc, char *argv[]);

/* xdvipdfmx reads the DVI and fonts a byte at a time with fgetc; macOS's stdio locks the stream on every call (~20% of
 * a page). A conversion is single-threaded, so these, linked ahead of libc's, skip the lock. Same bytes read. */
int fgetc(FILE *f) { return getc_unlocked(f); }
int getc(FILE *f) { return getc_unlocked(f); }
int fputc(int c, FILE *f) { return putc_unlocked(c, f); }
int putc(int c, FILE *f) { return putc_unlocked(c, f); }

/* kpathsea retries every miss case-insensitively, listing the directory (~1 ms a page: xdvipdfmx probes .dfont, CMaps,
 * glyph lists). On a case-insensitive volume an exact miss is also a case-folded miss, so when every place searched is
 * on one (the trees of the ls-R files, the working directory, the root), turning it off changes no result. */
static void casefold_off_if_moot(void)
{
  if (pathconf(".", _PC_CASE_SENSITIVE) != 0 || pathconf("/", _PC_CASE_SENSITIVE) != 0) return;
  for (unsigned i = 0; i < STR_LIST_LENGTH(kpse_def->db_dir_list); i++)
    if (pathconf(STR_LIST_ELT(kpse_def->db_dir_list, i), _PC_CASE_SENSITIVE) != 0) return;
  setenv("texmf_casefold_search", "0", 1);
}

static long long now_us(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (long long)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}

/* What xdvipdfmx's main does first, and the lookups every conversion makes: the cnf files, ls-R, and the search
 * paths of the formats it uses. All of it is the same in a fresh process; doing it here only moves it earlier. */
static void warm(const char *argv0)
{
  static const kpse_file_format_type fmts[] = {
    kpse_program_text_format, kpse_fontmap_format, kpse_enc_format, kpse_cmap_format, kpse_sfd_format,
    kpse_tfm_format, kpse_ofm_format, kpse_vf_format, kpse_ovf_format, kpse_type1_format, kpse_truetype_format,
    kpse_opentype_format, kpse_pict_format, kpse_tex_format, kpse_afm_format,
  };
  kpse_set_program_name(argv0, "dvipdfmx");
  (void)kpse_var_value("TEXMFDBS");  /* reads texmf.cnf and every ls-R */
  for (size_t i = 0; i < sizeof fmts / sizeof *fmts; i++) kpse_init_format(fmts[i]);
}

/* A request's line split at tabs into argv (argv[0] = the server's argv0). Returns argc, or -1. */
static int split(char *line, const char *argv0, char **dir, char **argv, int max)
{
  int argc = 0;
  char *s = line, *tab;
  *dir = s;
  if (!(tab = strchr(s, '\t'))) return -1;
  *tab = 0;
  s = tab + 1;
  argv[argc++] = (char *)argv0;
  while (argc < max - 1) {
    argv[argc++] = s;
    if (!(tab = strchr(s, '\t'))) break;
    *tab = 0;
    s = tab + 1;
  }
  argv[argc] = NULL;
  return argc;
}

/* The parked child: waits for its request on the pipe, then runs xdvipdfmx. */
static void child(int rfd, const char *argv0)
{
  static char line[65536];
  size_t n = 0;
  for (;;) {
    ssize_t r = read(rfd, line + n, sizeof line - 1 - n);
    if (r <= 0) _exit(0);  /* the server is gone, or quitting */
    n += (size_t)r;
    if (n && line[n - 1] == '\n') break;
    if (n == sizeof line - 1) _exit(2);
  }
  line[n - 1] = 0;
  close(rfd);
  char *dir, *argv[512];
  int argc = split(line, argv0, &dir, argv, 512);
  if (argc < 0 || (*dir && chdir(dir) != 0)) _exit(2);
  casefold_off_if_moot();
  int dn = open("/dev/null", O_WRONLY);
  if (dn >= 0) dup2(dn, 1);  /* stdout is the protocol: nothing of the conversion goes there */
  exit(dvipdfmx_stock_main(argc, argv));
}

static pid_t park(int *wfd, const char *argv0)
{
  int p[2];
  if (pipe(p) != 0) return -1;
  fflush(NULL);
  pid_t pid = fork();
  if (pid == 0) {
    close(p[1]);
    child(p[0], argv0);
  }
  close(p[0]);
  if (pid < 0) { close(p[1]); return -1; }
  fcntl(p[1], F_SETFD, FD_CLOEXEC);
  *wfd = p[1];
  return pid;
}

static int serve(const char *argv0)
{
  signal(SIGPIPE, SIG_IGN);
  warm(argv0);
  int wfd = -1;
  pid_t pid = park(&wfd, argv0);
  char *line = NULL;
  size_t cap = 0;
  ssize_t len;
  while ((len = getline(&line, &cap, stdin)) > 0) {
    long long t0 = now_us();
    if (line[len - 1] != '\n') { line = realloc(line, len + 2); line[len++] = '\n'; line[len] = 0; }
    int code = 2;
    if (pid > 0 && write(wfd, line, len) == len) {
      int st;
      close(wfd);
      while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
      code = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
    } else if (pid > 0) {
      close(wfd);
      kill(pid, SIGKILL);
      waitpid(pid, NULL, 0);
    }
    printf("done %d %lld\n", code, now_us() - t0);
    fflush(stdout);
    pid = park(&wfd, argv0);  /* the next one, while the client reads the PDF */
  }
  if (pid > 0) { close(wfd); waitpid(pid, NULL, 0); }
  return 0;
}

int main(int argc, char *argv[])
{
  /* xdvipdfmx names itself after argv[0] (the PDF's Producer and /ID depend on it): always "xdvipdfmx" here */
  static char name[4096];
  const char *slash = strrchr(argv[0], '/');
  snprintf(name, sizeof name, "%.*sxdvipdfmx", slash ? (int)(slash - argv[0] + 1) : 0, argv[0]);
  if (argc == 2 && !strcmp(argv[1], "serve")) return serve(name);
  argv[0] = name;
  return dvipdfmx_stock_main(argc, argv);
}
