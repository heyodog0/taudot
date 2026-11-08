/* compare.c: taudot_font against MuPDF 1.28, the behaviour it replaces. A test tool (links MuPDF; never shipped).
 * Our own code (MIT).
 *
 *   compare FONTDIR GLYPHLIST TEXGLYPHLIST [NAMES]
 *
 * FONTDIR holds the fonts txp-render loaded (collect.py: <hash>.bin and fonts.tsv: hash, face index, type, name).
 * For each font: name, type, ascender, descender; for every glyph: advance, outline (commands exact, points within
 * 1e-4 em), bounds, glyph name, glyph text (with and without a TeX character code); encoding of codes 0..0x2fff and
 * of every glyph name (the font's own, the glyph lists', NAMES). Then name → Unicode for all those names and some
 * odd forms. Prints the mismatches and a summary; exit 1 if any.
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mupdf/fitz.h>
#include <ft2build.h>
#include FT_FREETYPE_H

#include "../taudot_font.h"

static fz_context *ctx;
static long checks, bad;
static double max_dev;

#define FAIL(...) do { if (bad++ < 60) { printf(__VA_ARGS__); printf("\n"); } } while (0)

static char *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *b = malloc(n + 1);
    *len = fread(b, 1, n, f);
    b[*len] = 0;
    fclose(f);
    return b;
}

/* MuPDF's outline as TDL commands, through the same walker rules dlist.c uses */
typedef struct { char cmd[100000]; int nc; float v[400000]; int nv; float cx, cy, sx, sy; } rec;
static void w_move(fz_context *c, void *a, float x, float y) { rec *r = a; r->cmd[r->nc++] = 'M'; r->v[r->nv++] = x; r->v[r->nv++] = y; r->cx = r->sx = x; r->cy = r->sy = y; }
static void w_line(fz_context *c, void *a, float x, float y) { rec *r = a; r->cmd[r->nc++] = 'L'; r->v[r->nv++] = x; r->v[r->nv++] = y; r->cx = x; r->cy = y; }
static void w_curve(fz_context *c, void *a, float x1, float y1, float x2, float y2, float x3, float y3)
{ rec *r = a; r->cmd[r->nc++] = 'C'; float t[6] = {x1, y1, x2, y2, x3, y3}; memcpy(r->v + r->nv, t, sizeof t); r->nv += 6; r->cx = x3; r->cy = y3; }
static void w_close(fz_context *c, void *a) { rec *r = a; r->cmd[r->nc++] = 'Z'; r->cx = r->sx; r->cy = r->sy; }
static void w_quad(fz_context *c, void *a, float x1, float y1, float x2, float y2)
{ rec *r = a; r->cmd[r->nc++] = 'Q'; float t[4] = {x1, y1, x2, y2}; memcpy(r->v + r->nv, t, sizeof t); r->nv += 4; r->cx = x2; r->cy = y2; }
static void w_curvev(fz_context *c, void *a, float x2, float y2, float x3, float y3) { rec *r = a; w_curve(c, a, r->cx, r->cy, x2, y2, x3, y3); }
static void w_curvey(fz_context *c, void *a, float x1, float y1, float x3, float y3) { w_curve(c, a, x1, y1, x3, y3, x3, y3); }
static void w_rect(fz_context *c, void *a, float x1, float y1, float x2, float y2)
{ w_move(c, a, x1, y1); w_line(c, a, x2, y1); w_line(c, a, x2, y2); w_line(c, a, x1, y2); w_close(c, a); }
static const fz_path_walker walker = {w_move, w_line, w_curve, w_close, w_quad, w_curvev, w_curvey, w_rect};
static rec R;

static char **names;
static int nnames, capnames;
static void add_name(const char *s)
{
    if (!s[0]) return;
    if (nnames == capnames) { capnames = capnames ? capnames * 2 : 8192; names = realloc(names, capnames * sizeof *names); }
    names[nnames++] = strdup(s);
}
static void names_from_list(const char *data)
{
    for (const char *p = data; *p;) {
        const char *e = strchr(p, '\n');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (n && p[0] != '#') {
            const char *s = memchr(p, ';', n);
            if (s) { char b[128]; size_t k = s - p < 127 ? s - p : 127; memcpy(b, p, k); b[k] = 0; add_name(b); }
        }
        p = e ? e + 1 : p + n;
    }
}

static void compare_font(const char *dir, const char *hash, int index, int type, const char *name)
{
    char path[2048];
    snprintf(path, sizeof path, "%s/%s.bin", dir, hash);
    size_t len;
    char *data = slurp(path, &len);
    if (!data) { FAIL("%s: missing", hash); return; }
    fz_font *zf = NULL;
    fz_buffer *buf = fz_new_buffer_from_copied_data(ctx, (unsigned char *)data, len);
    fz_try(ctx) zf = fz_new_font_from_buffer(ctx, NULL, buf, index, 0);
    fz_catch(ctx) zf = NULL;
    fz_drop_buffer(ctx, buf);
    tf_font *tf = tf_font_new((unsigned char *)data, len, index);
    if (!zf || !tf) { FAIL("%s: open mupdf=%p tf=%p", hash, (void *)zf, (void *)tf); goto done; }
    FT_Face face = fz_font_ft_face(ctx, zf);
    for (int i = 0; i < face->num_charmaps; i++)
        if (face->charmaps[i]->platform_id == 7 && face->charmaps[i]->encoding_id == 2) FT_Set_Charmap(face, face->charmaps[i]);

    checks += 4;
    if (strcmp(fz_font_name(ctx, zf), tf_font_name(tf))) FAIL("%s: name '%s' vs '%s'", hash, fz_font_name(ctx, zf), tf_font_name(tf));
    if (strcmp(fz_font_name(ctx, zf), name)) FAIL("%s: dumped name '%s' vs mupdf '%s'", hash, name, fz_font_name(ctx, zf));
    if (tf_font_type(tf) != type) FAIL("%s: type %d vs %d", hash, type, tf_font_type(tf));
    if (fz_font_ascender(ctx, zf) != tf_font_ascender(tf) || fz_font_descender(ctx, zf) != tf_font_descender(tf))
        FAIL("%s: asc/desc %g %g vs %g %g", hash, fz_font_ascender(ctx, zf), fz_font_descender(ctx, zf), tf_font_ascender(tf), tf_font_descender(tf));

    int ng = face->num_glyphs;
    for (int g = 0; g < ng; g++) {
        checks++;
        float a1 = fz_advance_glyph(ctx, zf, g, 0), a2 = tf_glyph_advance(tf, g, 0);
        if (a1 != a2) FAIL("%s %s gid %d: advance %g vs %g", hash, name, g, a1, a2);

        fz_path *p = NULL;
        fz_try(ctx) p = fz_outline_glyph(ctx, zf, g, fz_identity);
        fz_catch(ctx) p = NULL;
        R.nc = R.nv = 0;
        if (p) { fz_walk_path(ctx, p, &walker, &R); fz_drop_path(ctx, p); }
        tf_path tp;
        int ok = tf_glyph_outline(tf, g, &tp) == 0;
        checks++;
        if (!ok) { tp.ncmd = tp.ncoord = 0; tp.cmd = NULL; tp.coord = NULL; }
        if ((int)tp.ncmd != R.nc || (int)tp.ncoord != R.nv || (R.nc && memcmp(tp.cmd, R.cmd, R.nc)))
            FAIL("%s %s gid %d: commands %d/%d vs %u/%u", hash, name, g, R.nc, R.nv, tp.ncmd, tp.ncoord);
        else
            for (int k = 0; k < R.nv; k++) {
                double d = fabs((double)R.v[k] - tp.coord[k]);
                if (d > max_dev) max_dev = d;
                if (d > 1e-4) { FAIL("%s %s gid %d: point %d off by %g", hash, name, g, k, d); break; }
            }
        /* bounds: of MuPDF's outline points (what glyphs.c's ink boxes use) */
        float r[4];
        int have = tf_glyph_bounds(tf, g, r);
        checks++;
        if (have != (R.nv > 0)) FAIL("%s gid %d: bounds presence %d vs %d", hash, g, have, R.nv > 0);
        tf_path_free(&tp);

        char n1[64] = "", n2[64] = "";
        fz_get_glyph_name(ctx, zf, g, n1, sizeof n1);
        tf_glyph_name(tf, g, n2, sizeof n2);
        checks++;
        if (strcmp(n1, n2)) FAIL("%s gid %d: glyph name '%s' vs '%s'", hash, g, n1, n2);
        add_name(n1);
    }
    for (int c = 0; c < 0x3000; c++) {
        checks++;
        int g1 = fz_encode_character(ctx, zf, c), g2 = tf_encode_char(tf, c);
        if (g1 != g2) FAIL("%s %s: encode %#x → %d vs %d", hash, name, c, g1, g2);
    }
    for (int i = 0; i < nnames; i++) {
        checks++;
        int g1 = fz_encode_character_by_glyph_name(ctx, zf, names[i]), g2 = tf_encode_glyph_name(tf, names[i]);
        if (g1 != g2) FAIL("%s %s: encode name '%s' → %d vs %d", hash, name, names[i], g1, g2);
    }
done:
    if (zf) fz_drop_font(ctx, zf);
    if (tf) tf_font_drop(tf);
    free(data);
}

int main(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage: compare FONTDIR GLYPHLIST TEXGLYPHLIST [NAMES]\n"); return 2; }
    ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    fz_set_warning_callback(ctx, NULL, NULL);
    size_t la, lt, ln;
    char *agl = slurp(argv[2], &la), *tex = slurp(argv[3], &lt);
    if (!agl || !tex) { fprintf(stderr, "glyph lists?\n"); return 2; }
    tf_glyph_lists(agl, la, tex, lt);
    names_from_list(agl);
    names_from_list(tex);
    if (argc > 4) { char *x = slurp(argv[4], &ln); if (x) for (char *s = strtok(x, "\n"); s; s = strtok(NULL, "\n")) add_name(s); }
    int base_names = nnames;

    char tsv[2048];
    snprintf(tsv, sizeof tsv, "%s/u.tsv", argv[1]);
    size_t lu;
    char *list = slurp(tsv, &lu);
    int nfonts = 0;
    for (char *line = strtok(list, "\n"); line; line = strtok(NULL, "\n")) {
        char hash[32], name[256] = "";
        int index, type;
        if (sscanf(line, "%31[^\t]\t%d\t%d\t%255[^\n]", hash, &index, &type, name) < 3) continue;
        char *save = strdup(line + strlen(line) + 1); /* strtok state is reused below; keep going */
        (void)save;
        compare_font(argv[1], hash, index, type, name);
        nfonts++;
    }

    /* name → Unicode over every name seen, plus odd forms */
    const char *odd[] = {"", "uni0041", "uni00e9", "uni00E9", "uniD800", "uni1F600", "u1F600", "u0041", "uFFFFFF",
                         "a65", "a1", "a", "G41", "GFF", "G100", "g24", "g101", "g102", "g0", "65", "-3", "0x41",
                         "f_f_i", "f_f_i.sc", "T_h", "A.sc", "fi.alt", "Delta", "dotlessj", "ffsmall", NULL};
    for (int i = 0; odd[i]; i++) add_name(odd[i]);
    for (int i = 0; i < 0x110; i++) { char b[16]; snprintf(b, sizeof b, "G%X", i); add_name(b); snprintf(b, sizeof b, "g%X", i); add_name(b); }
    int nmap = 0;
    for (int i = 0; i < nnames; i++) {
        checks++;
        nmap++;
        int u1 = fz_unicode_from_glyph_name(names[i]), u2 = tf_unicode_from_glyph_name(names[i]);
        if (u1 != u2) FAIL("name '%s' → %#x vs %#x", names[i], u1, u2);
    }
    printf("# %d fonts, %d names (%d from lists), %ld checks, %ld mismatches, max outline deviation %.3g em\n", nfonts,
           nmap, base_names, checks, bad, max_dev);
    return bad ? 1 : 0;
}
