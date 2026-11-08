/* paradraw.c: the paragraph preview's display list. #included by para.c.
   Copyright 2026 Ryan Truong. GPL-2.0-or-later.

   Reads the content stream pdfTeX wrote for the paragraph's lines (on a page of their own) the way a PDF viewer would,
   with the fonts' Type 1 outlines and the /Widths pdfTeX writes (writefont.c), and writes the glyphs and rules as a
   Taudot display list (clients/render/dlist.md, TDL 2: PAGE, FONT type 2 outlines, TEXT, RULE, FILL, END), placed in
   the page on screen over the paragraph's old lines: PDF points, y down from the page's top-left. */

/* ---- Type 1 fonts ---- */

static const struct { unsigned char code; const char *name; } p_std_enc[] = {
  {32,"space"},{33,"exclam"},{34,"quotedbl"},{35,"numbersign"},{36,"dollar"},{37,"percent"},{38,"ampersand"},
  {39,"quoteright"},{40,"parenleft"},{41,"parenright"},{42,"asterisk"},{43,"plus"},{44,"comma"},{45,"hyphen"},
  {46,"period"},{47,"slash"},{48,"zero"},{49,"one"},{50,"two"},{51,"three"},{52,"four"},{53,"five"},{54,"six"},
  {55,"seven"},{56,"eight"},{57,"nine"},{58,"colon"},{59,"semicolon"},{60,"less"},{61,"equal"},{62,"greater"},
  {63,"question"},{64,"at"},{65,"A"},{66,"B"},{67,"C"},{68,"D"},{69,"E"},{70,"F"},{71,"G"},{72,"H"},{73,"I"},{74,"J"},
  {75,"K"},{76,"L"},{77,"M"},{78,"N"},{79,"O"},{80,"P"},{81,"Q"},{82,"R"},{83,"S"},{84,"T"},{85,"U"},{86,"V"},{87,"W"},
  {88,"X"},{89,"Y"},{90,"Z"},{91,"bracketleft"},{92,"backslash"},{93,"bracketright"},{94,"asciicircum"},
  {95,"underscore"},{96,"quoteleft"},{97,"a"},{98,"b"},{99,"c"},{100,"d"},{101,"e"},{102,"f"},{103,"g"},{104,"h"},
  {105,"i"},{106,"j"},{107,"k"},{108,"l"},{109,"m"},{110,"n"},{111,"o"},{112,"p"},{113,"q"},{114,"r"},{115,"s"},
  {116,"t"},{117,"u"},{118,"v"},{119,"w"},{120,"x"},{121,"y"},{122,"z"},{123,"braceleft"},{124,"bar"},
  {125,"braceright"},{126,"asciitilde"},{161,"exclamdown"},{162,"cent"},{163,"sterling"},{164,"fraction"},{165,"yen"},
  {166,"florin"},{167,"section"},{168,"currency"},{169,"quotesingle"},{170,"quotedblleft"},{171,"guillemotleft"},
  {172,"guilsinglleft"},{173,"guilsinglright"},{174,"fi"},{175,"fl"},{177,"endash"},{178,"dagger"},{179,"daggerdbl"},
  {180,"periodcentered"},{182,"paragraph"},{183,"bullet"},{184,"quotesinglbase"},{185,"quotedblbase"},
  {186,"quotedblright"},{187,"guillemotright"},{188,"ellipsis"},{189,"perthousand"},{191,"questiondown"},{193,"grave"},
  {194,"acute"},{195,"circumflex"},{196,"tilde"},{197,"macron"},{198,"breve"},{199,"dotaccent"},{200,"dieresis"},
  {202,"ring"},{203,"cedilla"},{205,"hungarumlaut"},{206,"ogonek"},{207,"caron"},{208,"emdash"},{225,"AE"},
  {227,"ordfeminine"},{232,"Lslash"},{233,"Oslash"},{234,"OE"},{235,"ordmasculine"},{241,"ae"},{245,"dotlessi"},
  {248,"lslash"},{249,"oslash"},{250,"oe"},{251,"germandbls"}};

static const char *p_std_name(int code) {
  for (size_t i = 0; i < sizeof p_std_enc / sizeof *p_std_enc; i++) if (p_std_enc[i].code == code) return p_std_enc[i].name;
  return NULL;
}

struct t1cs { char *name; unsigned char *b; int n; };
struct t1path { int ncmd, ncoord, ccmd, ccoord; unsigned char *cmd; float *co; };
struct t1glyph { char *name; struct t1path path; int ok; };
struct t1font {
  char path[PATH_MAX];
  double fm[4];                 /* FontMatrix 2x2 */
  char *enc[256];               /* builtin encoding (glyph names), NULL: none */
  int lenIV;
  int nsubrs; unsigned char **subr; int *subrn;
  int ncs; struct t1cs *cs;     /* sorted by name */
  int ng, cg; struct t1glyph *g;  /* outlines made so far: the TDL glyph id is the index */
  int bad;
  char *clear; long nclear; unsigned char *bin; long nbin;  /* the font program, for the preview's PDF */
  double bbox[4];
};
#define P_NT1 32
static struct t1font *p_t1[P_NT1];
static int p_nt1;

static int t1cs_cmp(const void *a, const void *b) { return strcmp(((const struct t1cs *)a)->name, ((const struct t1cs *)b)->name); }

static unsigned char *t1_decrypt(const unsigned char *in, long n, unsigned short r, long *out_n) {
  unsigned char *o = malloc(n ? n : 1);
  for (long i = 0; i < n; i++) {
    unsigned char c = in[i];
    o[i] = c ^ (r >> 8);
    r = (unsigned short)((c + r) * 52845u + 22719u);
  }
  *out_n = n;
  return o;
}

static int p_hexv(int c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }

/* cleartext and the eexec part (still encrypted, binary) of a .pfb or .pfa */
static int t1_split(unsigned char *b, long n, char **clear, long *nclear, unsigned char **enc, long *nenc) {
  if (n > 6 && b[0] == 0x80) {
    long cap = n, nc = 0, ne = 0;
    *clear = malloc(cap + 1); *enc = malloc(cap);
    long i = 0;
    while (i + 2 <= n && b[i] == 0x80 && b[i + 1] != 3) {
      int t = b[i + 1];
      if (i + 6 > n) break;
      long len = b[i + 2] | b[i + 3] << 8 | b[i + 4] << 16 | (long)b[i + 5] << 24;
      i += 6;
      if (len < 0 || i + len > n) break;
      if (t == 1) { if (!ne) { memcpy(*clear + nc, b + i, len); nc += len; } }
      else if (t == 2) { memcpy(*enc + ne, b + i, len); ne += len; }
      i += len;
    }
    (*clear)[nc] = 0;
    *nclear = nc; *nenc = ne;
    return ne > 0 ? 0 : -1;
  }
  /* PFA: cleartext up to "eexec", then hex */
  char *e = NULL;
  for (long i = 0; i + 5 <= n; i++) if (!memcmp(b + i, "eexec", 5)) { e = (char *)b + i + 5; break; }
  if (!e) return -1;
  long nc = e - (char *)b;
  *clear = malloc(nc + 1); memcpy(*clear, b, nc); (*clear)[nc] = 0; *nclear = nc;
  *enc = malloc(n); long ne = 0; int hi = -1;
  for (char *p = e; p < (char *)b + n; p++) {
    int v = p_hexv(*p);
    if (v < 0) continue;
    if (hi < 0) hi = v; else { (*enc)[ne++] = (unsigned char)(hi << 4 | v); hi = -1; }
  }
  *nenc = ne;
  return 0;
}

static const unsigned char *t1_skipws(const unsigned char *p, const unsigned char *e) {
  while (p < e && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
  return p;
}

static struct t1font *t1_load(const char *path) {
  for (int i = 0; i < p_nt1; i++) if (!strcmp(p_t1[i]->path, path)) return p_t1[i]->bad ? NULL : p_t1[i];
  struct t1font *f = calloc(1, sizeof *f);
  snprintf(f->path, sizeof f->path, "%s", path);
  f->fm[0] = f->fm[3] = 0.001;
  f->lenIV = 4;
  if (p_nt1 < P_NT1) p_t1[p_nt1++] = f;
  long n;
  unsigned char *b = (unsigned char *)slurp(path, &n);
  char *clear = NULL; unsigned char *enc = NULL; long nclear = 0, nenc = 0;
  if (!b || t1_split(b, n, &clear, &nclear, &enc, &nenc)) { f->bad = 1; free(b); free(clear); free(enc); return NULL; }
  free(b);
  f->clear = malloc(nclear + 1); memcpy(f->clear, clear, nclear + 1); f->nclear = nclear;
  f->bin = malloc(nenc ? nenc : 1); memcpy(f->bin, enc, nenc); f->nbin = nenc;
  char *bb = strstr(clear, "/FontBBox");
  if (bb && (bb = strpbrk(bb, "[{"))) sscanf(bb + 1, "%lf %lf %lf %lf", &f->bbox[0], &f->bbox[1], &f->bbox[2], &f->bbox[3]);
  /* cleartext: FontMatrix and Encoding */
  char *m = strstr(clear, "/FontMatrix");
  if (m && (m = strchr(m, '['))) {
    double v[6];
    if (sscanf(m + 1, "%lf %lf %lf %lf %lf %lf", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) == 6)
      for (int k = 0; k < 4; k++) f->fm[k] = v[k];
  }
  char *e = strstr(clear, "/Encoding");
  if (e && !strncmp((const char *)t1_skipws((unsigned char *)e + 9, (unsigned char *)clear + nclear), "StandardEncoding", 16)) {
    for (int c = 0; c < 256; c++) { const char *s = p_std_name(c); if (s) f->enc[c] = strdup(s); }
  } else if (e) {
    for (char *p = e; (p = strstr(p, "dup ")); ) {
      int code; char name[128];
      if (sscanf(p, "dup %d /%127s put", &code, name) == 2 && code >= 0 && code < 256 && !f->enc[code]) {
        f->enc[code] = strdup(name);
      }
      p += 4;
      if (strstr(p, "readonly def") && strstr(p, "readonly def") < strstr(p, "dup ")) break;
    }
  }
  free(clear);
  /* the private part */
  long nd;
  unsigned char *d = t1_decrypt(enc, nenc, 55665, &nd);
  free(enc);
  const unsigned char *p = d + 4, *end = d + nd;
  const char *lv = memmem(p, end - p, "/lenIV", 6);
  if (lv) f->lenIV = atoi(lv + 6);
  const unsigned char *s = memmem(p, end - p, "/Subrs", 6);
  if (s) {
    s += 6;
    f->nsubrs = atoi((const char *)t1_skipws(s, end));
    if (f->nsubrs < 0 || f->nsubrs > 65536) f->nsubrs = 0;
    f->subr = calloc(f->nsubrs ? f->nsubrs : 1, sizeof *f->subr);
    f->subrn = calloc(f->nsubrs ? f->nsubrs : 1, sizeof *f->subrn);
    const unsigned char *q = s;
    for (;;) {
      q = memmem(q, end - q, "dup ", 4);
      if (!q) break;
      int idx, len; char tok[8];
      if (sscanf((const char *)q, "dup %d %d %7s", &idx, &len, tok) != 3) { q += 4; continue; }
      if (strcmp(tok, "RD") && strcmp(tok, "-|")) break;
      const unsigned char *r = (const unsigned char *)strstr((const char *)q, tok);
      if (!r) break;
      r += strlen(tok) + 1;
      if (r + len > end || idx < 0 || idx >= f->nsubrs) break;
      long dn;
      f->subr[idx] = t1_decrypt(r, len, 4330, &dn);
      f->subrn[idx] = len;
      q = r + len;
      const unsigned char *cs = memmem(q, end - q < 64 ? end - q : 64, "/CharStrings", 12);
      if (cs) break;
    }
  }
  const unsigned char *c = memmem(p, end - p, "/CharStrings", 12);
  if (!c) { f->bad = 1; free(d); return NULL; }
  c = memmem(c, end - c, "begin", 5);
  int cap = 0;
  while (c && c < end) {
    c = memchr(c, '/', end - c);
    if (!c) break;
    char name[128]; int len; char tok[8];
    int nn = 0;
    const unsigned char *q = c + 1;
    while (q < end && nn < 127 && *q > ' ' && *q != '/' && *q != '{' && *q != '[') name[nn++] = *q++;
    name[nn] = 0;
    if (sscanf((const char *)q, "%d %7s", &len, tok) != 2 || (strcmp(tok, "RD") && strcmp(tok, "-|"))) { c = q; continue; }
    const unsigned char *r = q;
    r = t1_skipws(r, end);
    while (r < end && *r > ' ') r++;          /* the length */
    r = t1_skipws(r, end);
    r += strlen(tok) + 1;                     /* the token and one space */
    if (len < 0 || r + len > end) break;
    if (f->ncs == cap) { cap = cap ? cap * 2 : 256; f->cs = realloc(f->cs, cap * sizeof *f->cs); }
    long dn;
    f->cs[f->ncs].name = strdup(name);
    f->cs[f->ncs].b = t1_decrypt(r, len, 4330, &dn);
    f->cs[f->ncs].n = len;
    f->ncs++;
    c = r + len;
  }
  free(d);
  qsort(f->cs, f->ncs, sizeof *f->cs, t1cs_cmp);
  if (!f->ncs) { f->bad = 1; return NULL; }
  return f;
}

static struct t1cs *t1_find(struct t1font *f, const char *name) {
  struct t1cs k = {(char *)name, NULL, 0};
  return bsearch(&k, f->cs, f->ncs, sizeof *f->cs, t1cs_cmp);
}

static void tp_add(struct t1path *p, char c, int nco, const float *co) {
  if (p->ncmd == p->ccmd) { p->ccmd = p->ccmd ? p->ccmd * 2 : 64; p->cmd = realloc(p->cmd, p->ccmd); }
  if (p->ncoord + nco > p->ccoord) { while (p->ncoord + nco > p->ccoord) p->ccoord = p->ccoord ? p->ccoord * 2 : 256; p->co = realloc(p->co, p->ccoord * sizeof *p->co); }
  p->cmd[p->ncmd++] = (unsigned char)c;
  memcpy(p->co + p->ncoord, co, nco * sizeof *co);
  p->ncoord += nco;
}

/* The Type 1 charstring interpreter: outlines in the font's units (FontMatrix applied by the caller). */
struct t1run {
  struct t1font *f; struct t1path *out;
  double st[64]; int sp;
  double ps[16]; int psp;           /* callothersubr's results, for pop */
  double x, y, ox, oy;              /* current point; the composite's offset (seac) */
  int open;                         /* a subpath is open */
  int flex; double fx[8], fy[8], fsx, fsy; int nflex;
  int depth;
};

static void tr_point(struct t1run *r, char c, double *xy, int n) {
  float co[6];
  for (int i = 0; i < n; i++) co[i] = (float)(xy[i] + (i % 2 ? r->oy : r->ox));
  tp_add(r->out, c, n, co);
}
static void tr_close(struct t1run *r) { if (r->open) { tp_add(r->out, 'Z', 0, NULL); r->open = 0; } }
static void tr_move(struct t1run *r, double dx, double dy) {
  r->x += dx; r->y += dy;
  if (r->flex) { if (r->nflex < 8) { r->fx[r->nflex] = r->x; r->fy[r->nflex] = r->y; r->nflex++; } return; }
  tr_close(r);
  double p[2] = {r->x, r->y};
  tr_point(r, 'M', p, 2);
  r->open = 1;
}
static void tr_line(struct t1run *r, double dx, double dy) {
  if (!r->open) { double p0[2] = {r->x, r->y}; tr_point(r, 'M', p0, 2); r->open = 1; }
  r->x += dx; r->y += dy;
  double p[2] = {r->x, r->y};
  tr_point(r, 'L', p, 2);
}
static void tr_curve(struct t1run *r, double a, double b, double c, double d, double e, double f) {
  if (!r->open) { double p0[2] = {r->x, r->y}; tr_point(r, 'M', p0, 2); r->open = 1; }
  double p[6];
  p[0] = r->x + a; p[1] = r->y + b; p[2] = p[0] + c; p[3] = p[1] + d; p[4] = p[2] + e; p[5] = p[3] + f;
  r->x = p[4]; r->y = p[5];
  tr_point(r, 'C', p, 6);
}

static int t1_glyph_run(struct t1run *r, const unsigned char *b, int n, int lenIV, int is_seac_part);

static int t1_charstring(struct t1run *r, const char *name, double ox, double oy) {
  struct t1cs *cs = t1_find(r->f, name);
  if (!cs) return -1;
  double sx = r->ox, sy = r->oy;
  r->ox = ox; r->oy = oy;
  r->sp = 0; r->psp = 0;
  int e = t1_glyph_run(r, cs->b, cs->n, r->f->lenIV, 1);
  r->ox = sx; r->oy = sy;
  return e;
}

static int t1_glyph_run(struct t1run *r, const unsigned char *b, int n, int lenIV, int top) {
  if (++r->depth > 16) return -1;
  int i = lenIV < 0 ? 0 : lenIV;
  (void)top;
  while (i < n) {
    int v = b[i++];
    if (v >= 32) {
      double num;
      if (v <= 246) num = v - 139;
      else if (v <= 250) { if (i >= n) return -1; num = (v - 247) * 256 + b[i++] + 108; }
      else if (v <= 254) { if (i >= n) return -1; num = -(v - 251) * 256 - b[i++] - 108; }
      else { if (i + 4 > n) return -1; num = (int32_t)((uint32_t)b[i] << 24 | (uint32_t)b[i + 1] << 16 | (uint32_t)b[i + 2] << 8 | b[i + 3]); i += 4; }
      if (r->sp < 64) r->st[r->sp++] = num;
      continue;
    }
    double *s = r->st;
    int sp = r->sp;
    switch (v) {
    case 1: case 3: break;                                  /* hstem, vstem */
    case 4: if (sp >= 1) tr_move(r, 0, s[sp - 1]); break;   /* vmoveto */
    case 5: if (sp >= 2) tr_line(r, s[sp - 2], s[sp - 1]); break;
    case 6: if (sp >= 1) tr_line(r, s[sp - 1], 0); break;
    case 7: if (sp >= 1) tr_line(r, 0, s[sp - 1]); break;
    case 8: if (sp >= 6) tr_curve(r, s[sp - 6], s[sp - 5], s[sp - 4], s[sp - 3], s[sp - 2], s[sp - 1]); break;
    case 9: tr_close(r); break;
    case 10: {                                              /* callsubr */
      if (sp < 1) return -1;
      int k = (int)s[sp - 1];
      r->sp = sp - 1;
      if (k == -1) continue;
      if (k < 0 || k >= r->f->nsubrs || !r->f->subr[k]) return -1;
      if (t1_glyph_run(r, r->f->subr[k], r->f->subrn[k], lenIV, 0) < 0) return -1;
      r->depth--;
      continue;  /* the subr leaves the stack as it is */
    }
    case 11: return 0;                                      /* return */
    case 12: {
      if (i >= n) return -1;
      int w = b[i++];
      switch (w) {
      case 0: case 1: case 2: break;                        /* dotsection, vstem3, hstem3 */
      case 6: {                                             /* seac asb adx ady bchar achar */
        if (sp < 5) return -1;
        double asb = s[sp - 5], adx = s[sp - 4], ady = s[sp - 3];
        int bc = (int)s[sp - 2], ac = (int)s[sp - 1];
        const char *bn = p_std_name(bc), *an = p_std_name(ac);
        if (!bn || !an) return -1;
        tr_close(r);
        double ox = r->ox, oy = r->oy;
        if (t1_charstring(r, bn, ox, oy) < 0) return -1;
        tr_close(r);
        if (t1_charstring(r, an, ox + adx - asb, oy + ady) < 0) return -1;
        tr_close(r);
        return 1;                                           /* like endchar */
      }
      case 7: if (sp >= 4) { r->x = s[sp - 4]; r->y = s[sp - 3]; } break;  /* sbw */
      case 12: if (sp >= 2) { s[sp - 2] = s[sp - 1] != 0 ? s[sp - 2] / s[sp - 1] : 0; r->sp = sp - 1; } continue;
      case 16: {                                            /* callothersubr: args n othersubr# */
        if (sp < 2) return -1;
        int k = (int)s[sp - 1], na = (int)s[sp - 2];
        if (na < 0 || na > sp - 2) return -1;
        double *args = s + sp - 2 - na;
        r->psp = 0;
        if (k == 1) { r->flex = 1; r->nflex = 0; r->fsx = r->x; r->fsy = r->y; }
        else if (k == 2) { }
        else if (k == 0 && na == 3) {  /* end of flex: two curves through the 7 points (the first is a reference) */
          r->flex = 0;
          if (r->nflex == 7) {
            double c1[6] = {r->fx[1], r->fy[1], r->fx[2], r->fy[2], r->fx[3], r->fy[3]};
            double c2[6] = {r->fx[4], r->fy[4], r->fx[5], r->fy[5], r->fx[6], r->fy[6]};
            if (!r->open) { double p0[2] = {r->fsx, r->fsy}; tr_point(r, 'M', p0, 2); r->open = 1; }
            tr_point(r, 'C', c1, 6);
            tr_point(r, 'C', c2, 6);
            r->x = r->fx[6]; r->y = r->fy[6];
          }
          r->ps[r->psp++] = r->y;  /* pop pop setcurrentpoint: x first */
          r->ps[r->psp++] = r->x;
        } else if (k == 3) r->ps[r->psp++] = -1;  /* hint replacement: the hints don't matter, so callsubr -1: none */
        else for (int j = 0; j < na; j++) r->ps[r->psp++] = args[j];
        r->sp = sp - 2 - na;
        continue;
      }
      case 17: if (r->psp > 0 && r->sp < 64) r->st[r->sp++] = r->ps[--r->psp]; continue;  /* pop */
      case 33: if (sp >= 2) { r->x = s[sp - 2]; r->y = s[sp - 1]; } break;  /* setcurrentpoint */
      default: break;
      }
      r->sp = 0;
      continue;
    }
    case 13: if (sp >= 2) { r->x = s[sp - 2]; r->y = 0; } break;  /* hsbw: sbx wx */
    case 14: tr_close(r); return 1;                               /* endchar */
    case 21: if (sp >= 2) tr_move(r, s[sp - 2], s[sp - 1]); break;
    case 22: if (sp >= 1) tr_move(r, s[sp - 1], 0); break;
    case 30: if (sp >= 4) tr_curve(r, 0, s[sp - 4], s[sp - 3], s[sp - 2], s[sp - 1], 0); break;
    case 31: if (sp >= 4) tr_curve(r, s[sp - 4], 0, s[sp - 3], s[sp - 2], 0, s[sp - 1]); break;
    default: break;
    }
    r->sp = 0;
  }
  return 0;
}

/* A glyph's outline by name, made once per font: its TDL glyph id (the index), or -1. */
static int t1_glyph(struct t1font *f, const char *name) {
  for (int i = 0; i < f->ng; i++) if (!strcmp(f->g[i].name, name)) return f->g[i].ok ? i : -1;
  if (f->ng == f->cg) { f->cg = f->cg ? f->cg * 2 : 64; f->g = realloc(f->g, f->cg * sizeof *f->g); }
  struct t1glyph *g = &f->g[f->ng];
  memset(g, 0, sizeof *g);
  g->name = strdup(name);
  struct t1run r;
  memset(&r, 0, sizeof r);
  r.f = f;
  r.out = &g->path;
  g->ok = t1_charstring(&r, name, 0, 0) >= 0;
  /* to em units by the FontMatrix */
  for (int i = 0; i + 1 < g->path.ncoord; i += 2) {
    double x = g->path.co[i], y = g->path.co[i + 1];
    g->path.co[i] = (float)(f->fm[0] * x + f->fm[2] * y);
    g->path.co[i + 1] = (float)(f->fm[1] * x + f->fm[3] * y);
  }
  f->ng++;
  return g->ok ? f->ng - 1 : -1;
}

/* An encoding file (.enc): 256 glyph names. */
struct penc { char path[PATH_MAX]; char *names[256]; };
#define P_NENC 16
static struct penc *p_encs[P_NENC];
static int p_nenc;

static struct penc *enc_load(const char *path) {
  for (int i = 0; i < p_nenc; i++) if (!strcmp(p_encs[i]->path, path)) return p_encs[i];
  long n;
  char *b = slurp(path, &n);
  if (!b) return NULL;
  struct penc *e = calloc(1, sizeof *e);
  snprintf(e->path, sizeof e->path, "%s", path);
  /* strip comments, then the names between [ and ] */
  for (long i = 0; i < n; i++) if (b[i] == '%') while (i < n && b[i] != '\n') b[i++] = ' ';
  char *p = strchr(b, '[');
  int c = 0;
  while (p && *p && *p != ']' && c < 256) {
    p = strchr(p, '/');
    if (!p) break;
    p++;
    int k = 0;
    char name[128];
    while (*p && *p > ' ' && *p != '/' && *p != ']' && k < 127) name[k++] = *p++;
    name[k] = 0;
    if (c == 0 && p_encs[0] == NULL && 0) {}
    e->names[c++] = strdup(name);
  }
  free(b);
  /* the first name in the file is the encoding's own (/Name [ ... ]): it came before '[' and was skipped */
  if (p_nenc < P_NENC) p_encs[p_nenc++] = e;
  return e;
}

/* ---- the display list ---- */

struct tdl { unsigned char *b; long n, cap; };
static void tdl_put(struct tdl *t, const void *p, long n) {
  if (t->n + n > t->cap) { while (t->n + n > t->cap) t->cap = t->cap ? t->cap * 2 : 65536; t->b = realloc(t->b, t->cap); }
  memcpy(t->b + t->n, p, n);
  t->n += n;
}
static void tdl_u8(struct tdl *t, unsigned v) { unsigned char c = (unsigned char)v; tdl_put(t, &c, 1); }
static void tdl_u16(struct tdl *t, unsigned v) { uint16_t x = (uint16_t)v; tdl_put(t, &x, 2); }
static void tdl_u32(struct tdl *t, uint32_t v) { tdl_put(t, &v, 4); }
static void tdl_f32(struct tdl *t, double v) { float x = (float)v; tdl_put(t, &x, 4); }
static void tdl_str(struct tdl *t, const char *s) { size_t n = strlen(s); tdl_u16(t, (unsigned)n); tdl_put(t, s, (long)n); }
static long tdl_begin(struct tdl *t, unsigned kind) { tdl_u8(t, kind); tdl_u32(t, 0); return t->n; }
static void tdl_end(struct tdl *t, long at) { uint32_t len = (uint32_t)(t->n - at); memcpy(t->b + at - 4, &len, 4); }

struct pglyph { int gid; float x, y, adv; };
struct prun { int font; float m[4]; float rgba[4]; float bbox[4]; int n, cap; struct pglyph *g; };

/* the content stream interpreter's state */
struct pgs { double ctm[6]; float fill[4]; };
struct pdraw {
  struct pout *o;
  double dx, dy, H;               /* mini page → page on screen: x + dx, dy + (H - y) (points) */
  struct pgs gs[32]; int ngs;
  double tm[6], tlm[6];
  double tc, tw, th, tl, trise, tfs;
  int tf;                         /* index in o->f, or -1 */
  struct t1font *t1[64]; struct penc *enc[64];
  struct prun *runs; int nruns, cruns;
  float rules[512][8]; int nrules;  /* bbox + rgba */
  const char *err;
  float ink[4];
};

static void mul6(const double *a, const double *b, double *o) {  /* o = a × b (PDF row-vector convention) */
  double r[6];
  r[0] = a[0] * b[0] + a[1] * b[2];
  r[1] = a[0] * b[1] + a[1] * b[3];
  r[2] = a[2] * b[0] + a[3] * b[2];
  r[3] = a[2] * b[1] + a[3] * b[3];
  r[4] = a[4] * b[0] + a[5] * b[2] + b[4];
  r[5] = a[4] * b[1] + a[5] * b[3] + b[5];
  memcpy(o, r, sizeof r);
}

static void pd_ink(struct pdraw *d, float x0, float y0, float x1, float y1) {
  if (x0 < d->ink[0]) d->ink[0] = x0;
  if (y0 < d->ink[1]) d->ink[1] = y0;
  if (x1 > d->ink[2]) d->ink[2] = x1;
  if (y1 > d->ink[3]) d->ink[3] = y1;
}

/* Show the bytes of a string with the current font. */
static void pd_show(struct pdraw *d, const unsigned char *s, int n) {
  if (d->tf < 0) { d->err = "nofont"; return; }
  struct pfont *f = &d->o->f[d->tf];
  struct t1font *t1 = d->t1[d->tf];
  struct penc *en = d->enc[d->tf];
  if (!t1) { d->err = "font"; return; }
  struct pgs *g = &d->gs[d->ngs];
  for (int i = 0; i < n; i++) {
    int code = s[i];
    const char *name = en ? en->names[code] : t1->enc[code];
    double w0 = 0;
    if (code >= f->bc && code < f->bc + f->nw) w0 = f->wd[code - f->bc] / 10.0;
    /* Trm = [tfs·th 0 0 tfs 0 rise] × Tm × CTM */
    double tsm[6] = {d->tfs * d->th, 0, 0, d->tfs, 0, d->trise}, trm[6];
    mul6(tsm, d->tm, trm);
    mul6(trm, g->ctm, trm);
    int gid = name ? t1_glyph(t1, name) : -1;
    if (name && strcmp(name, ".notdef") && gid < 0) { d->err = "glyph"; return; }
    if (gid >= 0) {
      /* runs: one per font and glyph matrix */
      float m[4] = {(float)trm[0], (float)-trm[1], (float)trm[2], (float)-trm[3]};
      struct prun *r = d->nruns ? &d->runs[d->nruns - 1] : NULL;
      if (!r || r->font != d->tf || memcmp(r->m, m, sizeof m) || memcmp(r->rgba, g->fill, sizeof g->fill)) {
        if (d->nruns == d->cruns) { d->cruns = d->cruns ? d->cruns * 2 : 16; d->runs = realloc(d->runs, d->cruns * sizeof *d->runs); }
        r = &d->runs[d->nruns++];
        memset(r, 0, sizeof *r);
        r->font = d->tf;
        memcpy(r->m, m, sizeof m);
        memcpy(r->rgba, g->fill, sizeof g->fill);
        r->bbox[0] = r->bbox[1] = 1e9;
        r->bbox[2] = r->bbox[3] = -1e9;
      }
      if (r->n == r->cap) { r->cap = r->cap ? r->cap * 2 : 64; r->g = realloc(r->g, r->cap * sizeof *r->g); }
      float x = (float)(trm[4] + d->dx), y = (float)(d->dy + d->H - trm[5]);
      double adv = w0 / 1000.0 * d->tfs * d->th;
      r->g[r->n++] = (struct pglyph){gid, x, y, (float)(adv * trm[0] / (d->tfs * d->th ? d->tfs * d->th : 1))};
      /* the glyph's ink: its outline's points through the glyph matrix (exact for the box TDL wants) */
      float x0 = x, x1 = x, y0 = y, y1 = y;
      struct t1path *gp = &t1->g[gid].path;
      for (int k = 0; k + 1 < gp->ncoord; k += 2) {
        float u = gp->co[k], v = gp->co[k + 1];
        float px = x + m[0] * u + m[2] * v, py = y + m[1] * u + m[3] * v;
        if (px < x0) x0 = px;
        if (px > x1) x1 = px;
        if (py < y0) y0 = py;
        if (py > y1) y1 = py;
      }
      if (x0 < r->bbox[0]) r->bbox[0] = x0;
      if (y0 < r->bbox[1]) r->bbox[1] = y0;
      if (x1 > r->bbox[2]) r->bbox[2] = x1;
      if (y1 > r->bbox[3]) r->bbox[3] = y1;
      pd_ink(d, x0, y0, x1, y1);
    }
    double tx = (w0 / 1000.0 * d->tfs + d->tc + (code == 32 ? d->tw : 0)) * d->th;
    double t[6] = {1, 0, 0, 1, tx, 0};
    mul6(t, d->tm, d->tm);
  }
}

/* ---- tokens ---- */

enum { T_NUM, T_NAME, T_STR, T_OP, T_ARR_OPEN, T_ARR_CLOSE, T_DICT, T_END };
struct ptok { int kind; double num; char s[256]; unsigned char *str; int n; };

static int pd_tok(const char **pp, const char *e, struct ptok *t, unsigned char *sbuf, int scap) {
  const char *p = *pp;
  for (;;) {
    while (p < e && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t' || *p == '\f' || *p == 0)) p++;
    if (p < e && *p == '%') { while (p < e && *p != '\n') p++; continue; }
    break;
  }
  if (p >= e) { *pp = p; t->kind = T_END; return 0; }
  char c = *p;
  if (c == '[') { *pp = p + 1; t->kind = T_ARR_OPEN; return 0; }
  if (c == ']') { *pp = p + 1; t->kind = T_ARR_CLOSE; return 0; }
  if (c == '/') {
    int k = 0;
    p++;
    while (p < e && !strchr(" \t\r\n\f/[]()<>{}%", *p) && k < 255) t->s[k++] = *p++;
    t->s[k] = 0;
    *pp = p; t->kind = T_NAME; return 0;
  }
  if (c == '(') {
    int depth = 1, n = 0;
    p++;
    while (p < e && depth > 0) {
      char ch = *p++;
      if (ch == '\\' && p < e) {
        char x = *p++;
        if (x >= '0' && x <= '7') {
          int v = x - '0';
          for (int k = 0; k < 2 && p < e && *p >= '0' && *p <= '7'; k++) v = v * 8 + (*p++ - '0');
          ch = (char)v;
        } else if (x == 'n') ch = '\n'; else if (x == 'r') ch = '\r'; else if (x == 't') ch = '\t';
        else if (x == 'b') ch = '\b'; else if (x == 'f') ch = '\f';
        else if (x == '\n') continue;
        else ch = x;
      } else if (ch == '(') depth++;
      else if (ch == ')') { if (--depth == 0) break; }
      if (n < scap) sbuf[n++] = (unsigned char)ch;
    }
    t->str = sbuf; t->n = n; t->kind = T_STR; *pp = p; return 0;
  }
  if (c == '<') {
    if (p + 1 < e && p[1] == '<') { *pp = p + 2; t->kind = T_DICT; return 0; }
    int n = 0, hi = -1;
    p++;
    while (p < e && *p != '>') {
      int v = p_hexv(*p++);
      if (v < 0) continue;
      if (hi < 0) hi = v; else { if (n < scap) sbuf[n++] = (unsigned char)(hi << 4 | v); hi = -1; }
    }
    if (hi >= 0 && n < scap) sbuf[n++] = (unsigned char)(hi << 4);
    *pp = p + 1; t->str = sbuf; t->n = n; t->kind = T_STR; return 0;
  }
  if (c == '>' && p + 1 < e && p[1] == '>') { *pp = p + 2; t->kind = T_DICT; return 0; }
  if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.') {
    char *q;
    t->num = strtod(p, &q);
    *pp = q > p ? q : p + 1; t->kind = T_NUM; return 0;
  }
  int k = 0;
  while (p < e && !strchr(" \t\r\n\f/[]()<>{}%", *p) && k < 255) t->s[k++] = *p++;
  t->s[k] = 0;
  if (!k) { *pp = p + 1; t->kind = T_OP; t->s[0] = 0; return 0; }
  *pp = p; t->kind = T_OP; return 0;
}

static void pd_rule(struct pdraw *d, double x, double y, double w, double h) {
  struct pgs *g = &d->gs[d->ngs];
  double *m = g->ctm;
  if (m[1] != 0 || m[2] != 0) { d->err = "rotated"; return; }
  double x0 = x * m[0] + m[4], y0 = y * m[3] + m[5], x1 = (x + w) * m[0] + m[4], y1 = (y + h) * m[3] + m[5];
  if (x0 > x1) { double t = x0; x0 = x1; x1 = t; }
  if (y0 > y1) { double t = y0; y0 = y1; y1 = t; }
  if (d->nrules == 512) { d->err = "rules"; return; }
  float *r = d->rules[d->nrules++];
  r[0] = (float)(x0 + d->dx); r[2] = (float)(x1 + d->dx);
  r[1] = (float)(d->dy + d->H - y1); r[3] = (float)(d->dy + d->H - y0);
  memcpy(r + 4, g->fill, 4 * sizeof(float));
  pd_ink(d, r[0], r[1], r[2], r[3]);
}

static const char *pd_run(struct pdraw *d, const char *p, const char *e) {
  static unsigned char sbuf[65536];
  double num[16]; int nn = 0;
  double rect[4]; int have_rect = 0;
  struct ptok t;
  /* TJ arrays: strings and numbers in order */
  struct { int is_str; double v; unsigned char *s; int n; } arr[512]; int na = 0, in_arr = 0;
  unsigned char abuf[65536]; int an = 0;
  int sn = 0; unsigned char *sv = NULL;
  while (!d->err) {
    pd_tok(&p, e, &t, sbuf, sizeof sbuf);
    if (t.kind == T_END) break;
    if (t.kind == T_ARR_OPEN) { in_arr = 1; na = 0; an = 0; continue; }
    if (t.kind == T_ARR_CLOSE) { in_arr = 0; continue; }
    if (t.kind == T_DICT) return "dict";
    if (in_arr) {
      if (na == 512) return "array";
      if (t.kind == T_NUM) { arr[na].is_str = 0; arr[na].v = t.num; na++; }
      else if (t.kind == T_STR) {
        if (an + t.n > (int)sizeof abuf) return "array";
        memcpy(abuf + an, t.str, t.n);
        arr[na].is_str = 1; arr[na].s = abuf + an; arr[na].n = t.n; an += t.n; na++;
      }
      continue;
    }
    if (t.kind == T_NUM) { if (nn < 16) num[nn++] = t.num; continue; }
    if (t.kind == T_STR) { sv = t.str; sn = t.n; continue; }
    if (t.kind == T_NAME) {
      if (t.s[0] == 'F' && t.s[1] >= '0' && t.s[1] <= '9') {
        int k = atoi(t.s + 1);
        d->tf = -1;
        for (int i = 0; i < d->o->nf; i++) if (d->o->f[i].num == k) d->tf = i;
      } else if (strcmp(t.s, "DeviceRGB") && strcmp(t.s, "DeviceGray") && strcmp(t.s, "DeviceCMYK")) d->tf = d->tf;
      continue;
    }
    const char *op = t.s;
    struct pgs *g = &d->gs[d->ngs];
    if (!strcmp(op, "q")) { if (d->ngs == 31) return "q"; d->gs[d->ngs + 1] = *g; d->ngs++; }
    else if (!strcmp(op, "Q")) { if (d->ngs > 0) d->ngs--; }
    else if (!strcmp(op, "cm") && nn == 6) { double m[6]; memcpy(m, num, sizeof m); mul6(m, g->ctm, g->ctm); }
    else if (!strcmp(op, "BT")) { double id[6] = {1, 0, 0, 1, 0, 0}; memcpy(d->tm, id, sizeof id); memcpy(d->tlm, id, sizeof id); }
    else if (!strcmp(op, "ET")) { }
    else if (!strcmp(op, "Tf") && nn >= 1) d->tfs = num[nn - 1];
    else if (!strcmp(op, "Tm") && nn == 6) { memcpy(d->tm, num, sizeof d->tm); memcpy(d->tlm, num, sizeof d->tlm); }
    else if ((!strcmp(op, "Td") || !strcmp(op, "TD")) && nn == 2) {
      double m[6] = {1, 0, 0, 1, num[0], num[1]};
      mul6(m, d->tlm, d->tlm);
      memcpy(d->tm, d->tlm, sizeof d->tm);
      if (op[1] == 'D') d->tl = -num[1];
    } else if (!strcmp(op, "T*")) {
      double m[6] = {1, 0, 0, 1, 0, -d->tl};
      mul6(m, d->tlm, d->tlm);
      memcpy(d->tm, d->tlm, sizeof d->tm);
    } else if (!strcmp(op, "Tc") && nn == 1) d->tc = num[0];
    else if (!strcmp(op, "Tw") && nn == 1) d->tw = num[0];
    else if (!strcmp(op, "Tz") && nn == 1) d->th = num[0] / 100.0;
    else if (!strcmp(op, "TL") && nn == 1) d->tl = num[0];
    else if (!strcmp(op, "Ts") && nn == 1) d->trise = num[0];
    else if (!strcmp(op, "Tr") && nn == 1) { if (num[0] != 0) return "render-mode"; }
    else if (!strcmp(op, "Tj") && sv) pd_show(d, sv, sn);
    else if (!strcmp(op, "TJ")) {
      for (int i = 0; i < na && !d->err; i++) {
        if (arr[i].is_str) pd_show(d, arr[i].s, arr[i].n);
        else {
          double tx = -arr[i].v / 1000.0 * d->tfs * d->th;
          double m[6] = {1, 0, 0, 1, tx, 0};
          mul6(m, d->tm, d->tm);
        }
      }
    } else if (!strcmp(op, "'") && sv) {
      double m[6] = {1, 0, 0, 1, 0, -d->tl};
      mul6(m, d->tlm, d->tlm);
      memcpy(d->tm, d->tlm, sizeof d->tm);
      pd_show(d, sv, sn);
    } else if (!strcmp(op, "re") && nn == 4) { memcpy(rect, num, sizeof rect); have_rect = 1; }
    else if (!strcmp(op, "f") || !strcmp(op, "F") || !strcmp(op, "f*")) {
      if (!have_rect) return "path";
      pd_rule(d, rect[0], rect[1], rect[2], rect[3]);
      have_rect = 0;
    } else if (!strcmp(op, "n")) have_rect = 0;
    else if (!strcmp(op, "g") && nn == 1) { g->fill[0] = g->fill[1] = g->fill[2] = (float)num[0]; g->fill[3] = 1; }
    else if (!strcmp(op, "rg") && nn == 3) { g->fill[0] = (float)num[0]; g->fill[1] = (float)num[1]; g->fill[2] = (float)num[2]; g->fill[3] = 1; }
    else if (!strcmp(op, "k") && nn == 4) {
      for (int i = 0; i < 3; i++) g->fill[i] = (float)((1 - num[i]) * (1 - num[3]));
      g->fill[3] = 1;
    } else if (!strcmp(op, "G") || !strcmp(op, "RG") || !strcmp(op, "K") || !strcmp(op, "w") || !strcmp(op, "J") ||
               !strcmp(op, "j") || !strcmp(op, "M") || !strcmp(op, "d") || !strcmp(op, "i") || !strcmp(op, "ri") ||
               !strcmp(op, "gs") || !strcmp(op, "BDC") || !strcmp(op, "BMC") || !strcmp(op, "EMC") ||
               !strcmp(op, "MP") || !strcmp(op, "DP")) { }
    else {  /* paths, images, shadings, forms: not drawn here */
      static char why[64];
      snprintf(why, sizeof why, "operator %.20s", op);
      for (char *c = why; *c; c++) if (*c < 0x21 || *c > 0x7e) *c = '?';
      return op[0] ? why : "syntax";
    }
    nn = 0; sv = NULL; sn = 0;
  }
  return d->err;
}

/* The paragraph's display list, placed over the old lines (anchor a): TDL at `path`. NULL or why not. */
static const char *p_pdf(struct pout *o, struct pdraw *d, const char *path);
static uint64_t p_t_draw0;
static const char *p_draw(struct pout *o, struct panchor *a, const char *path, const char *pdfpath) {
  p_t_draw0 = now_us();
  struct pdraw *d = calloc(1, sizeof *d);
  d->o = o;
  d->dx = sp2bp(a->l[0].x - o->l[0].shift - o->hx);
  d->dy = sp2bp(a->l[0].y - o->base0 - o->vy);
  d->H = sp2bp(o->ph ? o->ph : o->total);
  double id[6] = {1, 0, 0, 1, 0, 0};
  memcpy(d->gs[0].ctm, id, sizeof id);
  d->gs[0].fill[3] = 1;
  d->th = 1;
  d->tf = -1;
  d->ink[0] = d->ink[1] = 1e9; d->ink[2] = d->ink[3] = -1e9;
  if (o->nf > 64) { free(d); return "fonts"; }
  for (int i = 0; i < o->nf; i++) {
    if (strcmp(o->f[i].ff, "-")) d->t1[i] = t1_load(o->f[i].ff);
    if (strcmp(o->f[i].enc, "-")) d->enc[i] = enc_load(o->f[i].enc);
  }
  const char *err = pd_run(d, o->content, o->content + o->clen);
  if (!err && !d->nruns && !d->nrules) err = "nothing";
  if (err) {
    for (int i = 0; i < d->nruns; i++) free(d->runs[i].g);
    free(d->runs); free(d);
    return err;
  }
  struct tdl t = {0};
  tdl_put(&t, "TDL", 4);
  tdl_u32(&t, 2);
  long at = tdl_begin(&t, 0x01);
  tdl_u32(&t, (uint32_t)a->l[0].page); tdl_f32(&t, 0); tdl_f32(&t, 0);
  tdl_end(&t, at);
  int used[64] = {0};
  for (int i = 0; i < d->nruns; i++) used[d->runs[i].font] = 1;
  for (int i = 0; i < o->nf; i++) {
    if (!used[i] || !d->t1[i]) continue;
    struct t1font *f = d->t1[i];
    at = tdl_begin(&t, 0x02);
    tdl_u32(&t, (uint32_t)i); tdl_u8(&t, 2); tdl_str(&t, o->f[i].ps);
    /* the glyphs this list uses */
    int *g_used = calloc(f->ng ? f->ng : 1, sizeof *g_used), cnt = 0;
    for (int r = 0; r < d->nruns; r++) if (d->runs[r].font == i)
      for (int k = 0; k < d->runs[r].n; k++) if (!g_used[d->runs[r].g[k].gid]) { g_used[d->runs[r].g[k].gid] = 1; cnt++; }
    tdl_u32(&t, (uint32_t)cnt);
    for (int k = 0; k < f->ng; k++) {
      if (!g_used[k]) continue;
      struct t1path *pa = &f->g[k].path;
      tdl_u32(&t, (uint32_t)k);
      tdl_u32(&t, (uint32_t)pa->ncmd); tdl_u32(&t, (uint32_t)pa->ncoord);
      tdl_put(&t, pa->cmd, pa->ncmd);
      tdl_put(&t, pa->co, pa->ncoord * (long)sizeof(float));
    }
    free(g_used);
    tdl_end(&t, at);
  }
  for (int r = 0; r < d->nruns; r++) {
    struct prun *ru = &d->runs[r];
    at = tdl_begin(&t, 0x10);
    for (int k = 0; k < 4; k++) tdl_f32(&t, ru->bbox[k]);
    tdl_u8(&t, 0);
    for (int k = 0; k < 4; k++) tdl_f32(&t, ru->rgba[k]);
    tdl_u32(&t, (uint32_t)ru->font);
    for (int k = 0; k < 4; k++) tdl_f32(&t, ru->m[k]);
    tdl_u32(&t, (uint32_t)ru->n);
    for (int k = 0; k < ru->n; k++) {
      tdl_u32(&t, (uint32_t)ru->g[k].gid);
      tdl_f32(&t, ru->g[k].x); tdl_f32(&t, ru->g[k].y); tdl_f32(&t, ru->g[k].adv);
      tdl_str(&t, "");
    }
    tdl_end(&t, at);
    free(ru->g);
  }
  for (int r = 0; r < d->nrules; r++) {
    at = tdl_begin(&t, 0x13);
    for (int k = 0; k < 8; k++) tdl_f32(&t, d->rules[r][k]);
    tdl_end(&t, at);
  }
  at = tdl_begin(&t, 0x00);
  tdl_end(&t, at);
  uint64_t tq0 = now_us();
  if (pdfpath) p_pdf(d->o, d, pdfpath);
  if (getenv("TAUDOT_PARA_DEBUG")) fprintf(stderr, "para: draw run+tdl %llu pdf %llu\n", (unsigned long long)(tq0 - p_t_draw0), (unsigned long long)(now_us() - tq0));
  char tmp[PATH_MAX];
  snprintf(tmp, sizeof tmp, "%s.tmp", path);
  spit(tmp, (char *)t.b, t.n);
  rename(tmp, path);
  free(t.b);
  free(d->runs);
  free(d);
  return NULL;
}

/* ---- the preview as a PDF: the lines' content stream as pdfTeX wrote it, with the fonts' programs (whole, not
   subset), so Core Graphics draws its glyphs as it draws the exact page's ---- */

struct pbuf { char *b; long n, cap; };
static void pb_put(struct pbuf *b, const void *p, long n) {
  if (b->n + n > b->cap) { while (b->n + n > b->cap) b->cap = b->cap ? b->cap * 2 : 65536; b->b = realloc(b->b, b->cap); }
  memcpy(b->b + b->n, p, n);
  b->n += n;
}
static void pb_printf(struct pbuf *b, const char *fmt, ...) {
  char tmp[4096];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
  va_end(ap);
  if (n > 0) pb_put(b, tmp, n < (int)sizeof tmp ? n : (int)sizeof tmp - 1);
}

static const char *p_pdf(struct pout *o, struct pdraw *d, const char *path) {
  struct pbuf b = {0};
  long off[512];
  int nobj = 4;
  int fobj[64] = {0};
  pb_printf(&b, "%%PDF-1.5\n%%\xd0\xd4\xc5\xd8\n");
  double W = sp2bp(o->ph ? o->pw : o->width), H = sp2bp(o->ph ? o->ph : o->total);
  /* fonts: 3 objects each (font, descriptor, program) from 5 on */
  for (int i = 0; i < o->nf && nobj < 500; i++) if (d->t1[i]) { fobj[i] = nobj + 1; nobj += 3; }
  off[1] = b.n;
  pb_printf(&b, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
  off[2] = b.n;
  pb_printf(&b, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
  off[3] = b.n;
  pb_printf(&b, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.4f %.4f] /Contents 4 0 R /Resources << /ProcSet [/PDF /Text] /Font <<", W, H);
  for (int i = 0; i < o->nf; i++) if (fobj[i]) pb_printf(&b, " /F%d %d 0 R", o->f[i].num, fobj[i]);
  pb_printf(&b, " >> >> >>\nendobj\n");
  off[4] = b.n;
  pb_printf(&b, "4 0 obj\n<< /Length %ld >>\nstream\n", o->clen);
  pb_put(&b, o->content, o->clen);
  pb_printf(&b, "\nendstream\nendobj\n");
  for (int i = 0; i < o->nf; i++) {
    if (!fobj[i]) continue;
    struct pfont *f = &o->f[i];
    struct t1font *t = d->t1[i];
    struct penc *e = d->enc[i];
    int k = fobj[i];
    const char *name = strcmp(f->ps, "-") ? f->ps : "Font";
    off[k] = b.n;
    pb_printf(&b, "%d 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /%s /FontDescriptor %d 0 R", k, name, k + 1);
    if (f->nw > 0) {
      pb_printf(&b, " /FirstChar %d /LastChar %d /Widths [", f->bc, f->bc + f->nw - 1);
      for (int c = 0; c < f->nw; c++) {
        int w = f->wd[c];
        if (w % 10) pb_printf(&b, "%s%d.%d", c ? " " : "", w / 10, abs(w % 10)); else pb_printf(&b, "%s%d", c ? " " : "", w / 10);
      }
      pb_printf(&b, "]");
    }
    if (e) {
      pb_printf(&b, " /Encoding << /Type /Encoding /Differences [0");
      for (int c = 0; c < 256; c++) pb_printf(&b, " /%s", e->names[c] ? e->names[c] : ".notdef");
      pb_printf(&b, "] >>");
    }
    pb_printf(&b, " >>\nendobj\n");
    off[k + 1] = b.n;
    pb_printf(&b, "%d 0 obj\n<< /Type /FontDescriptor /FontName /%s /Flags 4 /FontBBox [%g %g %g %g] /ItalicAngle 0 "
                  "/Ascent %g /Descent %g /CapHeight %g /StemV 80 /FontFile %d 0 R >>\nendobj\n",
              k + 1, name, t->bbox[0], t->bbox[1], t->bbox[2], t->bbox[3], t->bbox[3], t->bbox[1], t->bbox[3], k + 2);
    off[k + 2] = b.n;
    pb_printf(&b, "%d 0 obj\n<< /Length %ld /Length1 %ld /Length2 %ld /Length3 0 >>\nstream\n", k + 2, t->nclear + t->nbin,
              t->nclear, t->nbin);
    pb_put(&b, t->clear, t->nclear);
    pb_put(&b, t->bin, t->nbin);
    pb_printf(&b, "\nendstream\nendobj\n");
  }
  long xref = b.n;
  pb_printf(&b, "xref\n0 %d\n0000000000 65535 f \n", nobj + 1);
  for (int i = 1; i <= nobj; i++) pb_printf(&b, "%010ld 00000 n \n", off[i]);
  pb_printf(&b, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%ld\n%%%%EOF\n", nobj + 1, xref);
  char tmp[PATH_MAX];
  snprintf(tmp, sizeof tmp, "%s.tmp", path);
  spit(tmp, b.b, b.n);
  rename(tmp, path);
  free(b.b);
  return NULL;
}
