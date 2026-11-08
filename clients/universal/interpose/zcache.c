// MIT. zcache: compressed streams reused across rollbacks, for engines linked against zlib as a dylib.
// A stream's input is held until Z_FINISH, then its deflate output comes from TAU_ZCACHE/<sha256 of the parameters
// and input> or from zlib itself (and is stored). zlib's output doesn't depend on how the input was split across
// Z_NO_FLUSH calls, so the bytes are the ones the engine would have written. Other flush modes: passed through.
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define ZLIB_CONST_SKIP
typedef unsigned char Bytef;
typedef struct z_stream_s {
  const Bytef *next_in;
  unsigned avail_in;
  unsigned long total_in;
  Bytef *next_out;
  unsigned avail_out;
  unsigned long total_out;
  const char *msg;
  void *state;
  void *zalloc, *zfree, *opaque;
  int data_type;
  unsigned long adler;
  unsigned long reserved;
} z_stream;
#define Z_NO_FLUSH 0
#define Z_FINISH 4
#define Z_OK 0
#define Z_STREAM_END 1
#define Z_BUF_ERROR (-5)

extern int deflate(z_stream *, int) __attribute__((weak_import));  // absent in statically linked engines
extern int deflateEnd(z_stream *) __attribute__((weak_import));  // absent in statically linked engines
extern int deflateReset(z_stream *) __attribute__((weak_import));  // absent in statically linked engines
extern int deflateInit_(z_stream *, int, const char *, int) __attribute__((weak_import));  // absent in statically linked engines
extern int deflateInit2_(z_stream *, int, int, int, int, int, const char *, int) __attribute__((weak_import));  // absent in statically linked engines

#define INTERPOSE(rep, orig) \
  __attribute__((used)) static struct { const void *r, *o; } _ipz_##rep \
      __attribute__((section("__DATA,__interpose"))) = {(const void *)rep, (const void *)orig}

extern int open_nc(const char *, int, ...) __asm("_open$NOCANCEL");
extern ssize_t read_nc(int, void *, size_t) __asm("_read$NOCANCEL");
extern ssize_t write_nc(int, const void *, size_t) __asm("_write$NOCANCEL");
extern int close_nc(int) __asm("_close$NOCANCEL");

typedef struct {
  z_stream *s;
  int params[4];  // level, windowBits, memLevel, strategy
  int mode;       // 0 defer, 1 drain, 2 pass
  unsigned char *in;
  size_t len, cap;
  unsigned char *out;
  size_t outlen, drained;
} zst;

static zst zs[16];
static const char *zdir;
static int zinit, zoff;
long tau_zcache_hits, tau_zcache_misses;

static zst *find(z_stream *s, int make) {
  for (int i = 0; i < 16; i++)
    if (zs[i].s == s) return &zs[i];
  if (!make) return NULL;
  for (int i = 0; i < 16; i++)
    if (!zs[i].s) { memset(&zs[i], 0, sizeof zs[i]); zs[i].s = s; return &zs[i]; }
  return NULL;
}

static void setup(void) {
  if (zinit) return;
  zinit = 1;
  zdir = getenv("TAU_ZCACHE");
  zoff = !zdir || !*zdir || (getenv("TAU_ZCACHE_OFF") != NULL);
  if (!zoff) mkdir(zdir, 0755);
}

static void reset(zst *z) {
  z->mode = zoff ? 2 : 0;
  z->len = 0;
  free(z->out);
  z->out = NULL;
  z->outlen = z->drained = 0;
}

static int my_deflateInit_(z_stream *s, int level, const char *v, int sz) {
  int r = deflateInit_(s, level, v, sz);
  setup();
  zst *z = find(s, 1);
  if (z) { z->params[0] = level, z->params[1] = 15, z->params[2] = 8, z->params[3] = 0; reset(z); }
  return r;
}
INTERPOSE(my_deflateInit_, deflateInit_);

static int my_deflateInit2_(z_stream *s, int level, int method, int wb, int ml, int st, const char *v, int sz) {
  int r = deflateInit2_(s, level, method, wb, ml, st, v, sz);
  setup();
  zst *z = find(s, 1);
  if (z) { z->params[0] = level, z->params[1] = wb, z->params[2] = ml, z->params[3] = st; reset(z); }
  return r;
}
INTERPOSE(my_deflateInit2_, deflateInit2_);

static int my_deflateReset(z_stream *s) {
  zst *z = find(s, 0);
  if (z) reset(z);
  return deflateReset(s);
}
INTERPOSE(my_deflateReset, deflateReset);

static int my_deflateEnd(z_stream *s) {
  zst *z = find(s, 0);
  if (z) { free(z->in); free(z->out); memset(z, 0, sizeof *z); }
  return deflateEnd(s);
}
INTERPOSE(my_deflateEnd, deflateEnd);

static void take_input(zst *z, z_stream *s) {
  if (z->len + s->avail_in > z->cap) {
    size_t c = z->cap ? z->cap : 65536;
    while (c < z->len + s->avail_in) c *= 2;
    z->in = realloc(z->in, c);
    z->cap = c;
  }
  memcpy(z->in + z->len, s->next_in, s->avail_in);
  z->len += s->avail_in;
  s->next_in += s->avail_in;
  s->total_in += s->avail_in;
  s->avail_in = 0;
}

static int load(const char *p, unsigned char **out, size_t *len) {
  int fd = open_nc(p, O_RDONLY);
  if (fd < 0) return -1;
  struct stat st;
  if (fstat(fd, &st)) { close_nc(fd); return -1; }
  *out = malloc(st.st_size ? st.st_size : 1);
  size_t got = 0;
  while (got < (size_t)st.st_size) {
    ssize_t r = read_nc(fd, *out + got, st.st_size - got);
    if (r <= 0) break;
    got += r;
  }
  close_nc(fd);
  if (got != (size_t)st.st_size) { free(*out); return -1; }
  *len = got;
  return 0;
}

static void store(const char *p, const unsigned char *b, size_t n) {
  char tmp[1200];
  size_t pl = strlen(p);
  memcpy(tmp, p, pl);
  memcpy(tmp + pl, ".t", 3);
  char pid[16];
  int k = 0;
  for (int x = getpid(); x; x /= 10) pid[k++] = '0' + x % 10;
  for (int i = 0; i < k; i++) tmp[pl + 2 + i] = pid[k - 1 - i];
  tmp[pl + 2 + k] = 0;
  int fd = open_nc(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;
  size_t done = 0;
  while (done < n) {
    ssize_t w = write_nc(fd, b + done, n - done);
    if (w <= 0) break;
    done += w;
  }
  close_nc(fd);
  if (done == n) rename(tmp, p);
  else unlink(tmp);
}

// Compress z->in with the real zlib on the caller's stream (its state is fresh: nothing was fed to it yet).
static int real_compress(zst *z, z_stream *s) {
  const Bytef *ni = s->next_in;
  unsigned ai = s->avail_in;
  Bytef *no = s->next_out;
  unsigned ao = s->avail_out;
  unsigned long ti = s->total_in;
  size_t cap = z->len / 2 + 1024;
  z->out = malloc(cap);
  s->next_in = z->in, s->avail_in = (unsigned)z->len, s->total_in = 0, s->total_out = 0;
  s->next_out = z->out, s->avail_out = (unsigned)cap;
  int r;
  for (;;) {
    r = deflate(s, Z_FINISH);
    if (r == Z_STREAM_END) break;
    if (r != Z_OK && r != Z_BUF_ERROR) break;
    size_t used = cap - s->avail_out;
    cap *= 2;
    z->out = realloc(z->out, cap);
    s->next_out = z->out + used, s->avail_out = (unsigned)(cap - used);
  }
  z->outlen = cap - s->avail_out;
  s->next_in = ni, s->avail_in = ai, s->next_out = no, s->avail_out = ao, s->total_in = ti;
  return r == Z_STREAM_END ? 0 : -1;
}

static int my_deflate(z_stream *s, int flush) {
  zst *z = find(s, 0);
  if (!z || z->mode == 2) return deflate(s, flush);
  if (z->mode == 0) {
    if (flush != Z_NO_FLUSH && flush != Z_FINISH) {
      if (z->len) {  // unexpected: give zlib what we held, then pass through
        const Bytef *ni = s->next_in;
        unsigned ai = s->avail_in;
        s->next_in = z->in, s->avail_in = (unsigned)z->len;
        z->mode = 2;
        int r = deflate(s, Z_NO_FLUSH);
        s->next_in = ni, s->avail_in = ai;
        if (r != Z_OK) return r;
        return deflate(s, flush);
      }
      z->mode = 2;
      return deflate(s, flush);
    }
    take_input(z, s);
    if (flush == Z_NO_FLUSH) {
      if (s->total_out < 2) s->total_out = 2;  // as zlib's header would; callers test it for "started"
      return Z_OK;
    }
    // Z_FINISH: from the cache, or compress and store
    char p[1100] = {0};
    int cached = 0;
    if (z->len >= 8192) {
      unsigned char h[CC_SHA256_DIGEST_LENGTH];
      CC_SHA256_CTX c;
      CC_SHA256_Init(&c);
      CC_SHA256_Update(&c, z->params, sizeof z->params);
      CC_SHA256_Update(&c, z->in, (CC_LONG)z->len);
      CC_SHA256_Final(h, &c);
      size_t dl = strlen(zdir);
      if (dl < 1000) {
        memcpy(p, zdir, dl);
        p[dl] = '/';
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
          p[dl + 1 + 2 * i] = "0123456789abcdef"[h[i] >> 4];
          p[dl + 2 + 2 * i] = "0123456789abcdef"[h[i] & 15];
        }
        cached = load(p, &z->out, &z->outlen) == 0;
      }
    }
    if (cached) tau_zcache_hits++;
    else {
      if (real_compress(z, s)) { z->mode = 2; return Z_STREAM_END; }
      if (p[0]) { store(p, z->out, z->outlen); tau_zcache_misses++; }
    }
    z->mode = 1;
    z->drained = 0;
  }
  // drain
  size_t k = z->outlen - z->drained;
  if (k > s->avail_out) k = s->avail_out;
  memcpy(s->next_out, z->out + z->drained, k);
  s->next_out += k;
  s->avail_out -= (unsigned)k;
  z->drained += k;
  s->total_out = z->drained;
  return z->drained == z->outlen ? Z_STREAM_END : Z_OK;
}
INTERPOSE(my_deflate, deflate);
