// tau-attach: a program in a pty that outlives the terminal showing it, shared by several terminals at once (dtach's
// idea). Taudot's Claude pane runs `claude` this way, so the conversation survives Taudot and shows in Rex too.
//
//   tau-attach new [-d] SOCKET -- CMD [ARG...]   start CMD in a pty behind SOCKET (a server in the background), then
//                                                attach this terminal to it (-d: don't)
//   tau-attach attach SOCKET                     attach this terminal: output, input, size; EOF on stdin detaches
//   tau-attach status SOCKET                     print CMD's pid; exit 1 when nothing runs there
//
// Several clients at once: all see the output; the one that typed last sets the pty's size (a client that has only
// attached sets it when nobody else has). A client attaching gets the last 256 KiB of output replayed, then the
// program is asked to redraw (a size change and back, which sends it SIGWINCH). When CMD exits, every client exits
// with its status and the socket goes.
//
// Wire format, both ways: a type byte, a 4-byte big-endian length, the payload.
//   server → client: 'H' u32 pid (on connect)   'O' output bytes   'X' i32 exit status
//   client → server: 'I' input bytes            'W' u16 rows, u16 cols
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

#define REPLAY (256 * 1024)
#define MAX_CLIENTS 32
#define MAX_PENDING (4 * 1024 * 1024)

static void die(const char *what) { fprintf(stderr, "tau-attach: %s: %s\n", what, strerror(errno)); exit(2); }

// ---- frames ----

typedef struct { unsigned char *p; size_t len, cap; } buf;

static void buf_add(buf *b, const void *d, size_t n) {
  if (b->len + n > b->cap) {
    size_t c = b->cap ? b->cap : 4096;
    while (c < b->len + n) c *= 2;
    unsigned char *q = realloc(b->p, c);
    if (!q) { fprintf(stderr, "tau-attach: out of memory\n"); exit(2); }
    b->p = q; b->cap = c;
  }
  memcpy(b->p + b->len, d, n);
  b->len += n;
}
static void buf_drop(buf *b, size_t n) { memmove(b->p, b->p + n, b->len - n); b->len -= n; }

static void frame(buf *b, char type, const void *d, uint32_t n) {
  unsigned char h[5] = { (unsigned char)type, n >> 24, n >> 16, n >> 8, n };
  buf_add(b, h, 5);
  if (n) buf_add(b, d, n);
}

// The next whole frame in `b`: its type and payload (valid until the next buf_drop), or 0.
static int next_frame(buf *b, char *type, unsigned char **data, uint32_t *n, size_t *used) {
  if (b->len < 5) return 0;
  uint32_t len = (uint32_t)b->p[1] << 24 | (uint32_t)b->p[2] << 16 | (uint32_t)b->p[3] << 8 | b->p[4];
  if (len > 16 * 1024 * 1024) return -1;
  if (b->len < 5 + (size_t)len) return 0;
  *type = (char)b->p[0]; *data = b->p + 5; *n = len; *used = 5 + len;
  return 1;
}

static int write_all(int fd, const void *d, size_t n) {
  const unsigned char *p = d;
  while (n) {
    ssize_t w = write(fd, p, n);
    if (w < 0) { if (errno == EINTR) continue; if (errno == EAGAIN) { struct pollfd q = { fd, POLLOUT, 0 }; poll(&q, 1, 1000); continue; } return -1; }
    p += w; n -= (size_t)w;
  }
  return 0;
}

static int sock_addr(const char *path, struct sockaddr_un *a) {
  memset(a, 0, sizeof *a);
  a->sun_family = AF_UNIX;
  if (strlen(path) >= sizeof a->sun_path) { errno = ENAMETOOLONG; return -1; }
  strcpy(a->sun_path, path);
  return 0;
}

static int connect_to(const char *path) {
  struct sockaddr_un a;
  if (sock_addr(path, &a) < 0) return -1;
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (s < 0) return -1;
  if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) { int e = errno; close(s); errno = e; return -1; }
  return s;
}

// ---- server ----

typedef struct { int fd; buf in, out; int has_size; unsigned short rows, cols; } client;

static client clients[MAX_CLIENTS];
static int nclients;
static int active = -1;  // the client whose size the pty has
static unsigned char replay[REPLAY];
static size_t replay_len, replay_at;  // a ring: replay_at is where the next byte goes
static int master = -1;
static pid_t child;

static void set_size(unsigned short rows, unsigned short cols) {
  struct winsize w = { rows, cols, 0, 0 };
  ioctl(master, TIOCSWINSZ, &w);
}

static void apply_active(void) {
  if (active >= 0 && clients[active].has_size) set_size(clients[active].rows, clients[active].cols);
}

// Ask the program to draw itself again: a size it isn't, then its size (SIGWINCH each time).
static void redraw(void) {
  struct winsize w;
  if (ioctl(master, TIOCGWINSZ, &w) < 0 || w.ws_row < 2) return;
  set_size(w.ws_row - 1, w.ws_col);
  set_size(w.ws_row, w.ws_col);
}

static void drop_client(int i) {
  close(clients[i].fd);
  free(clients[i].in.p); free(clients[i].out.p);
  clients[i] = clients[--nclients];
  if (active == i) active = -1;
  else if (active == nclients) active = i;
  // nobody typed since: the most recent client with a size takes over
  if (active < 0) for (int j = nclients - 1; j >= 0; j--) if (clients[j].has_size) { active = j; apply_active(); break; }
}

static void send_to(int i, char type, const void *d, uint32_t n) {
  frame(&clients[i].out, type, d, n);
  if (clients[i].out.len > MAX_PENDING) clients[i].out.len = 0, shutdown(clients[i].fd, SHUT_RDWR);  // far behind
}

static void handle_client(int i) {
  char type; unsigned char *d; uint32_t n; size_t used; int r;
  while ((r = next_frame(&clients[i].in, &type, &d, &n, &used)) == 1) {
    if (type == 'I') {
      if (active != i && clients[i].has_size) { active = i; apply_active(); }
      write_all(master, d, n);
    } else if (type == 'W' && n == 4) {
      clients[i].rows = (unsigned short)(d[0] << 8 | d[1]);
      clients[i].cols = (unsigned short)(d[2] << 8 | d[3]);
      int first = !clients[i].has_size;
      clients[i].has_size = clients[i].rows > 0 && clients[i].cols > 0;
      if (active < 0 && clients[i].has_size) active = i;
      if (active == i) apply_active();
      if (first && clients[i].has_size) redraw();  // just attached: draw the screen for it
    }
    buf_drop(&clients[i].in, used);
  }
  if (r < 0) shutdown(clients[i].fd, SHUT_RDWR);
}

static void accept_client(int ls) {
  int fd = accept(ls, NULL, NULL);
  if (fd < 0) return;
  if (nclients == MAX_CLIENTS) { close(fd); return; }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  int i = nclients++;
  memset(&clients[i], 0, sizeof clients[i]);
  clients[i].fd = fd;
  unsigned char pid[4] = { (unsigned char)(child >> 24), (unsigned char)(child >> 16), (unsigned char)(child >> 8), (unsigned char)child };
  send_to(i, 'H', pid, 4);
  // the replay, oldest first
  if (replay_len) {
    size_t start = replay_len < REPLAY ? 0 : replay_at;
    size_t first = replay_len < REPLAY ? replay_len : REPLAY - start;
    frame(&clients[i].out, 'O', replay + start, (uint32_t)first);
    if (replay_len >= REPLAY && replay_at) frame(&clients[i].out, 'O', replay, (uint32_t)replay_at);
  }
}

static void keep(const unsigned char *d, size_t n) {
  for (size_t k = 0; k < n; k++) { replay[replay_at] = d[k]; replay_at = (replay_at + 1) % REPLAY; }
  replay_len = replay_len + n > REPLAY ? REPLAY : replay_len + n;
}

static void serve(int ls, const char *path) {
  unsigned char b[65536];
  struct pollfd fds[MAX_CLIENTS + 2];
  for (;;) {
    fds[0] = (struct pollfd){ master, POLLIN, 0 };
    fds[1] = (struct pollfd){ ls, POLLIN, 0 };
    for (int i = 0; i < nclients; i++) fds[2 + i] = (struct pollfd){ clients[i].fd, POLLIN | (clients[i].out.len ? POLLOUT : 0), 0 };
    int nc = nclients;
    if (poll(fds, (nfds_t)(2 + nc), -1) < 0) { if (errno == EINTR) continue; break; }
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t r = read(master, b, sizeof b);
      if (r <= 0 && !(r < 0 && (errno == EINTR || errno == EAGAIN))) break;  // the program is gone
      if (r > 0) { keep(b, (size_t)r); for (int i = 0; i < nclients; i++) send_to(i, 'O', b, (uint32_t)r); }
    }
    // clients, highest index first (drop_client moves the last one into the gap)
    for (int i = nc - 1; i >= 0; i--) {
      short ev = fds[2 + i].revents;
      if (i >= nclients) continue;
      int gone = 0;
      if (ev & POLLIN) {
        ssize_t r = read(clients[i].fd, b, sizeof b);
        if (r > 0) { buf_add(&clients[i].in, b, (size_t)r); handle_client(i); }
        else if (r == 0 || (errno != EINTR && errno != EAGAIN)) gone = 1;
      } else if (ev & (POLLHUP | POLLERR)) gone = 1;
      if (!gone && clients[i].out.len && (ev & POLLOUT)) {
        ssize_t w = write(clients[i].fd, clients[i].out.p, clients[i].out.len);
        if (w > 0) buf_drop(&clients[i].out, (size_t)w);
        else if (w < 0 && errno != EAGAIN && errno != EINTR) gone = 1;
      }
      if (gone) drop_client(i);
    }
    if (fds[1].revents & POLLIN) accept_client(ls);
  }
  // the program ended: its status to everyone, then away
  int st = 0;
  waitpid(child, &st, 0);
  int code = WIFEXITED(st) ? WEXITSTATUS(st) : WIFSIGNALED(st) ? 128 + WTERMSIG(st) : 1;
  unsigned char c[4] = { (unsigned char)(code >> 24), (unsigned char)(code >> 16), (unsigned char)(code >> 8), (unsigned char)code };
  unlink(path);
  close(ls);
  for (int i = 0; i < nclients; i++) {
    frame(&clients[i].out, 'X', c, 4);
    fcntl(clients[i].fd, F_SETFL, fcntl(clients[i].fd, F_GETFL) & ~O_NONBLOCK);
    write_all(clients[i].fd, clients[i].out.p, clients[i].out.len);
    close(clients[i].fd);
  }
  exit(0);
}

// ---- client ----

static struct termios saved;
static int raw_on;
static volatile sig_atomic_t winched = 1;

static void restore_tty(void) { if (raw_on) tcsetattr(0, TCSADRAIN, &saved), raw_on = 0; }
static void on_winch(int s) { (void)s; winched = 1; }

static int attach(const char *path) {
  int s = connect_to(path);
  if (s < 0) { fprintf(stderr, "tau-attach: nothing at %s\n", path); return 1; }
  signal(SIGPIPE, SIG_IGN);
  if (isatty(0) && tcgetattr(0, &saved) == 0) {
    struct termios t = saved;
    cfmakeraw(&t);
    if (tcsetattr(0, TCSADRAIN, &t) == 0) { raw_on = 1; atexit(restore_tty); }
  }
  struct sigaction sa = { 0 };
  sa.sa_handler = on_winch;
  sigaction(SIGWINCH, &sa, NULL);
  buf in = { 0 }, out = { 0 };
  unsigned char b[65536];
  int stdin_open = 1;
  for (;;) {
    if (winched) {
      winched = 0;
      struct winsize w;
      if (ioctl(0, TIOCGWINSZ, &w) == 0 && w.ws_row && w.ws_col) {
        unsigned char d[4] = { w.ws_row >> 8, w.ws_row, w.ws_col >> 8, w.ws_col };
        frame(&out, 'W', d, 4);
      }
    }
    if (out.len) { if (write_all(s, out.p, out.len) < 0) break; out.len = 0; }
    struct pollfd fds[2] = { { s, POLLIN, 0 }, { stdin_open ? 0 : -1, POLLIN, 0 } };
    if (poll(fds, 2, -1) < 0) { if (errno == EINTR) continue; break; }
    if (fds[1].revents & (POLLIN | POLLHUP)) {
      ssize_t r = read(0, b, sizeof b);
      if (r > 0) frame(&out, 'I', b, (uint32_t)r);
      else if (r == 0 || errno != EINTR) { restore_tty(); return 0; }  // EOF: detach, the program keeps running
    }
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t r = read(s, b, sizeof b);
      if (r <= 0) { if (r < 0 && errno == EINTR) continue; break; }
      buf_add(&in, b, (size_t)r);
      char type; unsigned char *d; uint32_t n; size_t used; int k;
      while ((k = next_frame(&in, &type, &d, &n, &used)) == 1) {
        if (type == 'O') write_all(1, d, n);
        else if (type == 'X' && n == 4) {
          restore_tty();
          return (int)((uint32_t)d[0] << 24 | (uint32_t)d[1] << 16 | (uint32_t)d[2] << 8 | d[3]);
        }
        buf_drop(&in, used);
      }
      if (k < 0) break;
    }
  }
  restore_tty();
  return 1;  // the server went away without saying why
}

static int status(const char *path) {
  int s = connect_to(path);
  if (s < 0) return 1;
  buf in = { 0 };
  unsigned char b[4096];
  for (int tries = 0; tries < 50; tries++) {
    struct pollfd q = { s, POLLIN, 0 };
    if (poll(&q, 1, 100) <= 0) continue;
    ssize_t r = read(s, b, sizeof b);
    if (r <= 0) break;
    buf_add(&in, b, (size_t)r);
    char type; unsigned char *d; uint32_t n; size_t used;
    if (next_frame(&in, &type, &d, &n, &used) == 1 && type == 'H' && n == 4) {
      printf("%u\n", (uint32_t)d[0] << 24 | (uint32_t)d[1] << 16 | (uint32_t)d[2] << 8 | d[3]);
      return 0;
    }
  }
  return 1;
}

// ---- new ----

static int start(const char *path, char **cmd, int detached) {
  int s = connect_to(path);
  if (s >= 0) { close(s); fprintf(stderr, "tau-attach: already running at %s\n", path); return 3; }
  unlink(path);  // a stale socket from a server that died
  struct sockaddr_un a;
  if (sock_addr(path, &a) < 0) die(path);
  int ls = socket(AF_UNIX, SOCK_STREAM, 0);
  if (ls < 0) die("socket");
  mode_t old = umask(077);
  if (bind(ls, (struct sockaddr *)&a, sizeof a) < 0) die(path);
  umask(old);
  if (listen(ls, 16) < 0) die("listen");
  struct winsize w = { 24, 80, 0, 0 };
  if (!detached && isatty(0)) ioctl(0, TIOCGWINSZ, &w);
  if (!w.ws_row || !w.ws_col) w.ws_row = 24, w.ws_col = 80;
  int ready[2];
  if (pipe(ready) < 0) die("pipe");
  pid_t p = fork();
  if (p < 0) die("fork");
  if (p == 0) {
    // the server: its own session, no terminal of its own, quiet
    close(ready[0]);
    setsid();
    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    if (!getenv("TERM")) setenv("TERM", "xterm-256color", 1);
    child = forkpty(&master, NULL, NULL, &w);
    if (child < 0) _exit(2);
    if (child == 0) {
      close(ls);
      execvp(cmd[0], cmd);
      fprintf(stderr, "tau-attach: %s: %s\r\n", cmd[0], strerror(errno));
      _exit(127);
    }
    int nul = open("/dev/null", O_RDWR);
    if (nul >= 0) { dup2(nul, 0); dup2(nul, 1); dup2(nul, 2); if (nul > 2) close(nul); }
    if (write(ready[1], "k", 1) < 0) {}
    close(ready[1]);
    serve(ls, path);
  }
  close(ls);
  close(ready[1]);
  char k;
  if (read(ready[0], &k, 1) != 1) { fprintf(stderr, "tau-attach: the server didn't start\n"); return 2; }
  close(ready[0]);
  waitpid(p, NULL, WNOHANG);
  return detached ? 0 : attach(path);
}

static int usage(void) {
  fprintf(stderr, "usage: tau-attach new [-d] SOCKET -- CMD [ARG...]\n       tau-attach attach SOCKET\n       tau-attach status SOCKET\n");
  return 2;
}

int main(int argc, char **argv) {
  if (argc < 3) return usage();
  if (!strcmp(argv[1], "attach") && argc == 3) return attach(argv[2]);
  if (!strcmp(argv[1], "status") && argc == 3) return status(argv[2]);
  if (!strcmp(argv[1], "new")) {
    int i = 2, detached = 0;
    if (i < argc && !strcmp(argv[i], "-d")) detached = 1, i++;
    if (i + 2 >= argc || strcmp(argv[i + 1], "--")) return usage();
    return start(argv[i], argv + i + 2, detached);
  }
  return usage();
}
