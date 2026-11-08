// MIT. A SyncTeX reader for the paragraph pass: where a paragraph's lines are on an output's pages.
//
// Every line box of a paragraph is recorded with the source line its \par was read on (the blank line or the
// structural line after it), on pdfTeX, XeTeX and LuaTeX alike. So the lines of the paragraph that ends at line L of
// FILE are the hbox records `(tag,L:h,v:W,H,D` directly inside one vbox (a column), one after another.
// Positions are in sp from the paper's top-left (1in offsets included), v at the baseline. Included by tau-live.c.

typedef struct {
  int page;    // 0-based
  int parent;  // the enclosing vbox's number
  char kind;   // '(' hbox, '[' vbox, 'h' / 'v' void boxes
  int tag, line;
  int h, v, W, H, D;
} sx_rec;

typedef struct {
  char path[4600];
  time_t mtime;
  off_t size;
  sx_rec *r;  // the children of vboxes, in output order
  int n, cap;
  char **input;  // tag -> file path
  int ninput;
  double unit;
} sx_index;

static int sx_num(const char **p) {
  const char *s = *p;
  int neg = 0;
  if (*s == '-') neg = 1, s++;
  long v = 0;
  while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
  *p = s;
  return (int)(neg ? -v : v);
}

static void sx_free(sx_index *x) {
  free(x->r);
  for (int i = 0; i < x->ninput; i++) free(x->input[i]);
  free(x->input);
  memset(x, 0, sizeof *x);
}

// "(tag,line:h,v:W,H,D" (LuaTeX may add ",column" after line)
static int sx_box(const char *s, sx_rec *r) {
  const char *p = s + 1;
  r->tag = sx_num(&p);
  if (*p++ != ',') return 0;
  r->line = sx_num(&p);
  while (*p && *p != ':') p++;
  if (*p++ != ':') return 0;
  r->h = sx_num(&p);
  if (*p++ != ',') return 0;
  r->v = sx_num(&p);
  if (*p++ != ':') return 0;
  r->W = sx_num(&p);
  if (*p++ != ',') return 0;
  r->H = sx_num(&p);
  if (*p++ != ',') return 0;
  r->D = sx_num(&p);
  return 1;
}

static int sx_load(sx_index *x, const char *path) {
  struct stat st;
  if (stat(path, &st)) return 0;
  if (!strcmp(x->path, path) && x->mtime == st.st_mtime && x->size == st.st_size) return 1;
  sx_free(x);
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  char *b = malloc(st.st_size + 1);
  size_t n = fread(b, 1, st.st_size, f);
  fclose(f);
  b[n] = 0;
  snprintf(x->path, sizeof x->path, "%s", path);
  x->mtime = st.st_mtime, x->size = st.st_size, x->unit = 1;
  enum { DEPTH = 512 };
  int stk_id[DEPTH];
  char stk_kind[DEPTH];
  int depth = 0, ids = 0, page = -1;
  for (char *l = b, *e; l < b + n; l = e + 1) {
    e = memchr(l, '\n', b + n - l);
    if (!e) e = b + n;
    *e = 0;
    char c = *l;
    if (c == '(' || c == '[' || c == 'h' || c == 'v') {
      if (page >= 0 && depth > 0 && stk_kind[depth - 1] == '[') {
        sx_rec r = {.page = page, .parent = stk_id[depth - 1], .kind = c};
        if (sx_box(l, &r)) {
          if (x->n == x->cap) x->cap = x->cap ? 2 * x->cap : 4096, x->r = realloc(x->r, x->cap * sizeof *x->r);
          x->r[x->n++] = r;
        }
      }
      if ((c == '(' || c == '[') && depth < DEPTH) stk_id[depth] = ++ids, stk_kind[depth++] = c;
    } else if (c == ')' || c == ']') {
      if (depth > 0) depth--;
    } else if (c == '{') {
      page = atoi(l + 1) - 1, depth = 0;
    } else if (c == '}') {
      depth = 0;
    } else if (!strncmp(l, "Input:", 6)) {
      char *q;
      long t = strtol(l + 6, &q, 10);
      if (*q == ':' && t >= 0 && t < 100000) {
        if (t >= x->ninput) {
          x->input = realloc(x->input, (t + 1) * sizeof *x->input);
          memset(x->input + x->ninput, 0, (t + 1 - x->ninput) * sizeof *x->input);
          x->ninput = t + 1;
        }
        free(x->input[t]);
        x->input[t] = strdup(q + 1);
      }
    } else if (!strncmp(l, "Unit:", 5)) {
      x->unit = atof(l + 5);
    }
  }
  free(b);
  return 1;
}

// Does synctex's path for a tag name REL (relative to the project)? ("DIR/./main.tex", "DIR/main.tex", "main.tex")
static int sx_is_file(const char *p, const char *rel) {
  size_t lp = strlen(p), lr = strlen(rel);
  if (lp >= 4 && lr >= 4 && strcmp(rel + lr - 4, ".tex") && !strcmp(p + lp - 4, ".tex")) lp -= 4;  // (\input foo)
  if (lp < lr || strncmp(p + lp - lr, rel, lr)) return 0;
  return lp == lr || p[lp - lr - 1] == '/';
}

typedef struct {
  int found;   // 0: no line of this paragraph; 1: lines in one run; -1: split (columns, pages); -2: a gap
  int page, first, n;  // the run: x->r[first .. first+n)
} sx_para;

// The lines of the paragraph whose \par is at line LINE of REL
static sx_para sx_find(const sx_index *x, const char *rel, int line) {
  sx_para o = {0, -1, -1, 0};
  int parent = -1, last = -1;
  for (int i = 0; i < x->n; i++) {
    const sx_rec *r = &x->r[i];
    if (r->kind != '(' || r->line != line || r->tag < 0 || r->tag >= x->ninput || !x->input[r->tag] ||
        !sx_is_file(x->input[r->tag], rel))
      continue;
    if (o.found == 0) {
      o.found = 1, o.page = r->page, o.first = i, o.n = 1, parent = r->parent, last = i;
      continue;
    }
    if (r->parent != parent) { o.found = -1; return o; }
    for (int k = last + 1; k < i; k++)
      if (x->r[k].parent == parent) { o.found = -2; return o; }  // something else between (a display)
    o.n++, last = i;
  }
  return o;
}
