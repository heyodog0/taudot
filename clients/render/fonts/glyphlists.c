/* glyphlists.c: glyph names → Unicode for taudot_font.h. Copyright (c) 2026 the Taudot authors, MIT (LICENSE).
 *
 * The names come from the Adobe Glyph List and lcdf-typetools' texglyphlist.txt, read at run time from the TeX
 * bundle (tf_glyph_lists), so neither list is part of this code. Lists are read as MuPDF's table was built from the
 * same two files: in order, skipping comments; per name, the first alternative whose code points are all in the BMP;
 * a name seen before is ignored. Names with one code point answer lookups; the other names a code point has
 * ("duplicates", in list order) help find a glyph by name. */

#include "taudot_font.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tables.h"

typedef struct { char *name; int ucs; } entry;
static entry *singles;    /* names with one code point, sorted by name (strcmp) */
static int nsingles;
typedef struct { int ucs; const char **names; } dup;
static dup *dups;         /* code points with several names, sorted by code point */
static int ndups;
static const char *none[] = {NULL};

/* the names seen so far (any number of code points): open addressing */
static char **seen_tab;
static size_t seen_cap, seen_n;

static unsigned long hash(const char *s)
{
    unsigned long h = 5381;
    while (*s)
        h = h * 33 + (unsigned char)*s++;
    return h;
}

static int seen_add(char *name) /* 1 if new */
{
    if (seen_n * 2 >= seen_cap) {
        size_t cap = seen_cap ? seen_cap * 2 : 16384;
        char **t = calloc(cap, sizeof *t);
        for (size_t i = 0; i < seen_cap; i++)
            if (seen_tab[i]) {
                size_t k = hash(seen_tab[i]) & (cap - 1);
                while (t[k]) k = (k + 1) & (cap - 1);
                t[k] = seen_tab[i];
            }
        free(seen_tab);
        seen_tab = t;
        seen_cap = cap;
    }
    size_t k = hash(name) & (seen_cap - 1);
    while (seen_tab[k]) {
        if (!strcmp(seen_tab[k], name))
            return 0;
        k = (k + 1) & (seen_cap - 1);
    }
    seen_tab[k] = name;
    seen_n++;
    return 1;
}

static entry *order; /* single names in list order */
static int norder, caporder;

static void read_list(const char *data, size_t len)
{
    const char *p = data, *end = data + len;
    while (p < end) {
        const char *e = memchr(p, '\n', end - p);
        size_t n = e ? (size_t)(e - p) : (size_t)(end - p);
        const char *line = p;
        p = e ? e + 1 : end;
        if (n && line[n - 1] == '\r')
            n--;
        if (n == 0 || line[0] == '#')
            continue;
        const char *semi = memchr(line, ';', n);
        if (!semi || memchr(semi + 1, ';', n - (size_t)(semi + 1 - line)))
            continue;
        size_t nl = (size_t)(semi - line);
        char *name = malloc(nl + 1);
        memcpy(name, line, nl);
        name[nl] = 0;
        /* alternatives separated by ',', code points by ' ': the first all in the BMP counts */
        const char *a = semi + 1, *aend = line + n;
        int added = 0;
        while (a < aend && !added) {
            const char *ce = memchr(a, ',', (size_t)(aend - a));
            if (!ce)
                ce = aend;
            int first = 0, nc = 0, ok = 1;
            for (const char *q = a; q < ce;) {
                char *qe;
                long v = strtol(q, &qe, 16);
                if (qe == q) { ok = 0; break; }
                if (nc++ == 0) first = (int)v;
                if (v > 0xffff) ok = 0;
                q = qe;
                if (q < ce && *q == ' ') q++;
            }
            if (ok && nc > 0) {
                if (seen_add(name) && nc == 1) {
                    if (norder == caporder) {
                        caporder = caporder ? caporder * 2 : 4096;
                        order = realloc(order, (size_t)caporder * sizeof *order);
                    }
                    order[norder].name = name;
                    order[norder].ucs = first;
                    norder++;
                }
                added = 1; /* a name's first usable alternative, even if the name was seen */
            }
            a = ce < aend ? ce + 1 : aend;
        }
    }
}

static int by_name(const void *a, const void *b) { return strcmp(((const entry *)a)->name, ((const entry *)b)->name); }

typedef struct { int ucs, pos; } up;
static int by_ucs_pos(const void *a, const void *b)
{
    const up *x = a, *y = b;
    if (x->ucs != y->ucs) return x->ucs < y->ucs ? -1 : 1;
    return x->pos < y->pos ? -1 : x->pos > y->pos;
}

void tf_glyph_lists(const char *agl, size_t agl_len, const char *tex, size_t tex_len)
{
    if (singles)
        return; /* once */
    if (agl) read_list(agl, agl_len);
    if (tex) read_list(tex, tex_len);
    nsingles = norder;
    singles = malloc((size_t)(nsingles ? nsingles : 1) * sizeof *singles);
    memcpy(singles, order, (size_t)nsingles * sizeof *singles);
    qsort(singles, (size_t)nsingles, sizeof *singles, by_name);

    up *u = malloc((size_t)(norder ? norder : 1) * sizeof *u);
    for (int i = 0; i < norder; i++) { u[i].ucs = order[i].ucs; u[i].pos = i; }
    qsort(u, (size_t)norder, sizeof *u, by_ucs_pos);
    for (int i = 0; i < norder;) {
        int j = i;
        while (j < norder && u[j].ucs == u[i].ucs) j++;
        if (j - i > 1) {
            dups = realloc(dups, (size_t)(ndups + 1) * sizeof *dups);
            dups[ndups].ucs = u[i].ucs;
            dups[ndups].names = malloc((size_t)(j - i + 1) * sizeof(char *));
            for (int k = i; k < j; k++) dups[ndups].names[k - i] = order[u[k].pos].name;
            dups[ndups].names[j - i] = NULL;
            ndups++;
        }
        i = j;
    }
    free(u);
}

const char *const *tf__dup_names(int ucs)
{
    int l = 0, r = ndups - 1;
    while (l <= r) {
        int m = (l + r) / 2;
        if (ucs < dups[m].ucs)
            r = m - 1;
        else if (ucs > dups[m].ucs)
            l = m + 1;
        else
            return (const char *const *)dups[m].names;
    }
    return none;
}

static int read_num(const char *p, int base)
{
    char *e;
    long v = strtol(p, &e, base);
    if (*e != 0)
        return 0;
    return (int)v;
}

int tf_unicode_from_glyph_name(const char *name)
{
    char buf[64];
    snprintf(buf, sizeof buf, "%s", name);
    char *p = strchr(buf, '.');
    if (p)
        *p = 0;
    p = strchr(buf, '_');
    if (p) {
        /* f-ligatures written with underscores; otherwise the first component */
        if (!strcmp(buf, "f_f")) strcpy(buf, "ff");
        else if (!strcmp(buf, "f_f_i")) strcpy(buf, "ffi");
        else if (!strcmp(buf, "f_f_l")) strcpy(buf, "ffl");
        else if (!strcmp(buf, "f_i")) strcpy(buf, "fi");
        else if (!strcmp(buf, "f_l")) strcpy(buf, "fl");
        else *p = 0;
    }
    int l = 0, r = nsingles - 1;
    while (l <= r) {
        int m = (l + r) / 2, c = strcmp(buf, singles[m].name);
        if (c < 0)
            r = m - 1;
        else if (c > 0)
            l = m + 1;
        else
            return singles[m].ucs;
    }
    int code;
    if (buf[0] == 'u' && buf[1] == 'n' && buf[2] == 'i' && strlen(buf) == 7)
        code = read_num(buf + 3, 16);
    else if (buf[0] == 'u')
        code = read_num(buf + 1, 16);
    else if (buf[0] == 'a' && buf[1] != 0 && buf[2] != 0)
        code = read_num(buf + 1, 10);
    else if (buf[0] == 'G') { /* old DOS fonts: G%x in code page 437 */
        code = read_num(buf + 1, 16);
        code = (code > 0 && code < 256) ? tf_cp437[code] : 0;
    } else if (buf[0] == 'g') { /* old Ghostscript subsets: g%x, the TrueType standard glyph index */
        code = read_num(buf + 1, 16);
        code = (code > 0 && code < 258) ? tf_tt_standard[code] : 0;
    } else
        code = read_num(buf, 10);
    return (code > 0 && code <= 0x10ffff) ? code : 0xfffd;
}
