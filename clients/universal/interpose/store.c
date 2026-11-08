// MIT. TeX Live files from the TeX Live store (docs/texstore.md), inside libtau: no Python, no helper program.
//
// A lookup that misses under the TeX Live tree (TEXSTORE_ROOT / TAU_TLROOT) asks store_fetch(PATH):
//   index (TEXSTORE_INDEX, else images/NAME/rREV, asked once and kept in the cache) -> the path's F row (binary
//   search) -> its package's manifest -> the file's SHA-512 -> the cache by hash, else files/<sha512> from the store,
//   gunzipped and checked -> written into the tree atomically.
// Only hashes decide what is accepted. The cache is the reference client's (tools/texstore/client.py):
// TEXSTORE_CACHE (default ~/Library/Caches/taudot/texstore)/objects/<2 hex>/<sha512>, uncompressed, and
// images/<name>/r<rev> holding the index hash.
//
// libcurl and zlib are the system's, loaded with dlopen on the first fetch (an engine that finds every file never
// loads them). The index is read once per engine process; snapshots (forks) inherit it. Each fetch uses a fresh curl
// handle, so a forked process never shares a connection with its parent. Included by tau.c.
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>

typedef void CURL;
static struct {
  int tried, ok;
  CURL *(*easy_init)(void);
  int (*easy_setopt)(CURL *, int, ...);
  int (*easy_perform)(CURL *);
  int (*easy_getinfo)(CURL *, int, ...);
  void (*easy_cleanup)(CURL *);
  int (*inflateInit2_)(void *, int, const char *, int);
  int (*inflate)(void *, int);
  int (*inflateEnd)(void *);
  const char *(*zlibVersion)(void);
} st_lib;

// curl's option and info numbers (curl.h, stable ABI)
enum {
  ST_CURLOPT_URL = 10002, ST_CURLOPT_WRITEDATA = 10001, ST_CURLOPT_WRITEFUNCTION = 20011,
  ST_CURLOPT_USERAGENT = 10018, ST_CURLOPT_FOLLOWLOCATION = 52, ST_CURLOPT_TIMEOUT = 13,
  ST_CURLOPT_CONNECTTIMEOUT = 78, ST_CURLOPT_NOSIGNAL = 99, ST_CURLOPT_FAILONERROR = 45,
  ST_CURLINFO_RESPONSE_CODE = 0x200002,
};

// a z_stream as zlib.h lays it out (64-bit)
typedef struct {
  const unsigned char *next_in;
  unsigned avail_in;
  unsigned long total_in;
  unsigned char *next_out;
  unsigned avail_out;
  unsigned long total_out;
  const char *msg;
  void *state, *zalloc, *zfree, *opaque;
  int data_type;
  unsigned long adler, reserved;
} st_zstream;

static int st_load(void) {
  if (st_lib.tried) return st_lib.ok;
  st_lib.tried = 1;
  void *c = dlopen("/usr/lib/libcurl.4.dylib", RTLD_NOW | RTLD_LOCAL);
  void *z = dlopen("/usr/lib/libz.1.dylib", RTLD_NOW | RTLD_LOCAL);
  if (!c || !z) return 0;
  st_lib.easy_init = dlsym(c, "curl_easy_init");
  st_lib.easy_setopt = dlsym(c, "curl_easy_setopt");
  st_lib.easy_perform = dlsym(c, "curl_easy_perform");
  st_lib.easy_getinfo = dlsym(c, "curl_easy_getinfo");
  st_lib.easy_cleanup = dlsym(c, "curl_easy_cleanup");
  st_lib.inflateInit2_ = dlsym(z, "inflateInit2_");
  st_lib.inflate = dlsym(z, "inflate");
  st_lib.inflateEnd = dlsym(z, "inflateEnd");
  st_lib.zlibVersion = dlsym(z, "zlibVersion");
  st_lib.ok = st_lib.easy_init && st_lib.easy_setopt && st_lib.easy_perform && st_lib.easy_getinfo &&
              st_lib.easy_cleanup && st_lib.inflateInit2_ && st_lib.inflate && st_lib.inflateEnd && st_lib.zlibVersion;
  return st_lib.ok;
}

typedef struct { unsigned char *p; size_t n, cap; } st_buf;
static size_t st_write(char *d, size_t sz, size_t nm, void *u) {
  st_buf *b = u;
  size_t k = sz * nm;
  if (b->n + k > b->cap) {
    size_t c = b->cap ? b->cap : 65536;
    while (c < b->n + k) c *= 2;
    unsigned char *q = realloc(b->p, c);
    if (!q) return 0;
    b->p = q, b->cap = c;
  }
  memcpy(b->p + b->n, d, k);
  b->n += k;
  return k;
}

static int st_offline;  // the last failure was the network's (not a missing object): the driver says "offline"

// GET URL: 0 and the body on 200
static int st_http(const char *url, st_buf *out) {
  memset(out, 0, sizeof *out);
  CURL *h = st_lib.easy_init();
  if (!h) return -1;
  st_lib.easy_setopt(h, ST_CURLOPT_URL, url);
  st_lib.easy_setopt(h, ST_CURLOPT_USERAGENT, "taudot-texstore");
  st_lib.easy_setopt(h, ST_CURLOPT_FOLLOWLOCATION, 1L);
  st_lib.easy_setopt(h, ST_CURLOPT_NOSIGNAL, 1L);
  st_lib.easy_setopt(h, ST_CURLOPT_CONNECTTIMEOUT, 10L);
  st_lib.easy_setopt(h, ST_CURLOPT_TIMEOUT, 120L);
  st_lib.easy_setopt(h, ST_CURLOPT_WRITEFUNCTION, st_write);
  st_lib.easy_setopt(h, ST_CURLOPT_WRITEDATA, out);
  int r = st_lib.easy_perform(h);
  long code = 0;
  st_lib.easy_getinfo(h, ST_CURLINFO_RESPONSE_CODE, &code);
  st_lib.easy_cleanup(h);
  if (r != 0) st_offline = 1;  // couldn't connect, resolve, or finish
  if (r != 0 || code != 200) { free(out->p); memset(out, 0, sizeof *out); return -1; }
  return 0;
}

static int st_gunzip(const unsigned char *in, size_t n, st_buf *out) {
  memset(out, 0, sizeof *out);
  st_zstream z;
  memset(&z, 0, sizeof z);
  if (st_lib.inflateInit2_(&z, 16 + 15, st_lib.zlibVersion(), (int)sizeof z) != 0) return -1;
  out->cap = n * 4 + 4096;
  out->p = malloc(out->cap);
  z.next_in = in, z.avail_in = (unsigned)n;
  int r;
  do {
    if (out->n == out->cap) out->cap *= 2, out->p = realloc(out->p, out->cap);
    z.next_out = out->p + out->n, z.avail_out = (unsigned)(out->cap - out->n);
    r = st_lib.inflate(&z, 0);
    out->n = out->cap - z.avail_out;
  } while (r == 0);
  st_lib.inflateEnd(&z);
  if (r != 1) { free(out->p); memset(out, 0, sizeof *out); return -1; }  // Z_STREAM_END
  return 0;
}

static void st_hex(const unsigned char *d, size_t n, char hex[129]) {
  unsigned char md[64];
  CC_SHA512(d, (CC_LONG)n, md);
  for (int i = 0; i < 64; i++) snprintf(hex + 2 * i, 3, "%02x", md[i]);
}

static char st_url[1024], st_cache[1024], st_root[1024];

static int st_mkdirs(char *p) {  // the directories above P
  for (char *s = p + 1; *s; s++)
    if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
  return 0;
}
static int st_write_atomic(const char *path, const unsigned char *d, size_t n, int exec) {
  char tmp[2200], p[2048];
  snprintf(p, sizeof p, "%s", path);
  st_mkdirs(p);
  snprintf(tmp, sizeof tmp, "%s.%d.part", path, getpid());
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, exec ? 0755 : 0644);
  if (fd < 0) return -1;
  size_t k = 0;
  while (k < n) {
    ssize_t w = write(fd, d + k, n - k);
    if (w <= 0) { close(fd); unlink(tmp); return -1; }
    k += w;
  }
  close(fd);
  return rename(tmp, path);
}
static unsigned char *st_slurp(const char *p, size_t *n) {
  int fd = open(p, O_RDONLY);
  if (fd < 0) return NULL;
  struct stat s;
  if (fstat(fd, &s)) { close(fd); return NULL; }
  unsigned char *b = malloc(s.st_size + 1);
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

// The content named HASH: from the cache, else the store; checked before it is used or cached
static unsigned char *st_obj(const char *hash, size_t *n) {
  char p[2048], hex[129];
  snprintf(p, sizeof p, "%s/objects/%.2s/%s", st_cache, hash, hash);
  unsigned char *b = st_slurp(p, n);
  if (b) {
    st_hex(b, *n, hex);
    if (!strcmp(hex, hash)) return b;
    free(b);  // a damaged cache entry: fetch it again
  }
  char url[1400];
  snprintf(url, sizeof url, "%s/files/%s", st_url, hash);
  st_buf gz, raw;
  if (st_http(url, &gz)) return NULL;
  int bad = st_gunzip(gz.p, gz.n, &raw);
  free(gz.p);
  if (bad) return NULL;
  st_hex(raw.p, raw.n, hex);
  if (strcmp(hex, hash)) { free(raw.p); return NULL; }
  st_write_atomic(p, raw.p, raw.n, 0);
  *n = raw.n;
  return raw.p;
}

// The image index: F rows (path order) and P rows (package order), in place
static struct {
  int state;  // 0 not read, 1 read, -1 failed
  char *data;
  char **f;  // F rows: "F\tpath\tsize\tpkg"
  long nf;
  char **p;  // P rows: "P\tpkg\tmanifest\t..."
  long np;
} st_idx;

static int st_index(void) {
  if (st_idx.state) return st_idx.state > 0;
  st_idx.state = -1;
  char h[200] = "";
  const char *pin = getenv("TEXSTORE_INDEX");
  if (pin && *pin) snprintf(h, sizeof h, "%s", pin);
  else {
    const char *img = getenv("TEXSTORE_IMAGE");
    const char *at = img ? strchr(img, '@') : NULL;
    if (!at) return 0;
    char ptr[2048];
    snprintf(ptr, sizeof ptr, "%s/images/%.*s/%s", st_cache, (int)(at - img), img, at + 1);
    size_t n;
    unsigned char *b = st_slurp(ptr, &n);
    if (b) { snprintf(h, sizeof h, "%.*s", (int)strcspn((char *)b, "\r\n"), (char *)b); free(b); }
    else {
      char url[1400];
      snprintf(url, sizeof url, "%s/images/%.*s/%s", st_url, (int)(at - img), img, at + 1);
      st_buf r;
      if (st_http(url, &r)) return 0;
      snprintf(h, sizeof h, "%.*s", (int)strcspn((char *)r.p, "\r\n"), (char *)r.p);
      free(r.p);
      char line[200];
      int l = snprintf(line, sizeof line, "%s\n", h);
      st_write_atomic(ptr, (unsigned char *)line, l, 0);
    }
  }
  if (strlen(h) != 128) return 0;
  size_t n;
  st_idx.data = (char *)st_obj(h, &n);
  if (!st_idx.data) return 0;
  if (strncmp(st_idx.data, "texstore\t1\n", 11)) return 0;  // format version 1 only
  long cf = 0, cp = 0;
  for (char *l = st_idx.data, *e; l < st_idx.data + n; l = e + 1) {
    e = memchr(l, '\n', st_idx.data + n - l);
    if (!e) e = st_idx.data + n;
    *e = 0;
    if (l[0] == 'F' && l[1] == '\t') {
      if (st_idx.nf == cf) cf = cf ? 2 * cf : 262144, st_idx.f = realloc(st_idx.f, cf * sizeof *st_idx.f);
      st_idx.f[st_idx.nf++] = l;
    } else if (l[0] == 'P' && l[1] == '\t') {
      if (st_idx.np == cp) cp = cp ? 2 * cp : 8192, st_idx.p = realloc(st_idx.p, cp * sizeof *st_idx.p);
      st_idx.p[st_idx.np++] = l;
    }
  }
  st_idx.state = 1;
  return 1;
}

// field K (0-based) of a tab-separated row, into OUT
static int st_field(const char *row, int k, char *out, size_t cap) {
  for (int i = 0; i < k; i++) {
    row = strchr(row, '\t');
    if (!row) return 0;
    row++;
  }
  size_t l = strcspn(row, "\t");
  if (l >= cap) return 0;
  memcpy(out, row, l);
  out[l] = 0;
  return 1;
}
static int st_cmp_field(const char *row, const char *key) {  // field 1 of ROW against KEY (byte order)
  const char *a = strchr(row, '\t') + 1;
  size_t l = strcspn(a, "\t"), kl = strlen(key);
  int c = memcmp(a, key, l < kl ? l : kl);
  return c ? c : (l < kl ? -1 : l > kl);
}
static const char *st_bsearch(char **rows, long n, const char *key) {
  long lo = 0, hi = n;
  while (lo < hi) {
    long m = (lo + hi) / 2;
    int c = st_cmp_field(rows[m], key);
    if (!c) return rows[m];
    if (c < 0) lo = m + 1;
    else hi = m;
  }
  return NULL;
}

// Manifests read so far (one per package; a compile touches ~60)
static struct { char pkg[256]; char *data; size_t n; } st_man[128];
static int st_nman;

static const char *st_manifest(const char *pkg, size_t *n) {
  for (int i = 0; i < st_nman; i++)
    if (!strcmp(st_man[i].pkg, pkg)) { *n = st_man[i].n; return st_man[i].data; }
  const char *row = st_bsearch(st_idx.p, st_idx.np, pkg);
  char mh[200];
  if (!row || !st_field(row, 2, mh, sizeof mh)) return NULL;
  size_t mn;
  char *m = (char *)st_obj(mh, &mn);
  if (!m) return NULL;
  int k = st_nman < 128 ? st_nman++ : 127;
  if (k == 127 && st_man[k].data) free(st_man[k].data);
  snprintf(st_man[k].pkg, sizeof st_man[k].pkg, "%s", pkg);
  st_man[k].data = m, st_man[k].n = mn;
  *n = mn;
  return m;
}

// PATH (under the tree) into the tree from the store. 1: there now; 0: not in TeX Live, or it failed
// (st_offline set when the network was the reason).
static int store_fetch(const char *path) {
  st_offline = 0;
  if (!st_url[0]) {
    const char *u = getenv("TEXSTORE_URL");
    if (!u || !*u) return 0;
    snprintf(st_url, sizeof st_url, "%s", u);
    size_t l = strlen(st_url);
    while (l && st_url[l - 1] == '/') st_url[--l] = 0;
    const char *c = getenv("TEXSTORE_CACHE"), *home = getenv("HOME");
    if (c && *c) snprintf(st_cache, sizeof st_cache, "%s", c);
    else snprintf(st_cache, sizeof st_cache, "%s/Library/Caches/taudot/texstore", home ? home : "/tmp");
    const char *r = getenv("TEXSTORE_ROOT");
    snprintf(st_root, sizeof st_root, "%s", r && *r ? r : tlroot);
    size_t k = strlen(st_root);
    while (k > 1 && st_root[k - 1] == '/') st_root[--k] = 0;
  }
  size_t rl = strlen(st_root);
  if (!rl || strncmp(path, st_root, rl) || path[rl] != '/') return 0;
  const char *rel = path + rl + 1;
  if (!st_load() || !st_index()) return 0;
  const char *row = st_bsearch(st_idx.f, st_idx.nf, rel);
  if (!row) return 0;  // not in TeX Live: no network
  char pkg[256];
  if (!st_field(row, 3, pkg, sizeof pkg)) return 0;
  size_t mn;
  const char *m = st_manifest(pkg, &mn);
  if (!m) return 0;
  // the manifest's line for REL: path, size, sha512, x
  size_t l = strlen(rel);
  for (const char *s = m; s < m + mn;) {
    const char *e = memchr(s, '\n', m + mn - s);
    if (!e) e = m + mn;
    if ((size_t)(e - s) > l && !memcmp(s, rel, l) && s[l] == '\t') {
      char line[600], size_s[32], hash[200], x[8] = "";
      snprintf(line, sizeof line, "%.*s", (int)(e - s), s);
      if (!st_field(line, 1, size_s, sizeof size_s) || !st_field(line, 2, hash, sizeof hash)) return 0;
      st_field(line, 3, x, sizeof x);
      size_t n;
      unsigned char *b = st_obj(hash, &n);
      if (!b) return 0;
      int ok = n == (size_t)atoll(size_s) && st_write_atomic(path, b, n, x[0] == 'x') == 0;
      free(b);
      return ok;
    }
    s = e + 1;
  }
  return 0;
}
