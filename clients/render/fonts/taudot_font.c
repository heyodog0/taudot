/* taudot_font.c: see taudot_font.h.
 *
 * Copyright (c) 2026 the Taudot authors. MIT License (see LICENSE in this folder).
 *
 * Written from FreeType's documentation and from measuring MuPDF 1.28's answers (tests/compare.c); no MuPDF code.
 */

#include "taudot_font.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include FT_MODULE_H
#include FT_ADVANCES_H


struct tf_font {
    int refs;
    unsigned char *data;
    size_t len;
    FT_Face face;
    int index;
    int type;
    char name[32];
    float ascender, descender;
    int written; /* sfnt file written this process */
    char path[1100];
};

/* ---- the library: like MuPDF, a library with the default modules and no environment properties ---- */

static void *mem_alloc(FT_Memory m, long size) { (void)m; return malloc(size); }
static void mem_free(FT_Memory m, void *p) { (void)m; free(p); }
static void *mem_realloc(FT_Memory m, long cur, long size, void *p) { (void)m; (void)cur; return realloc(p, size); }
static struct FT_MemoryRec_ memory = {NULL, mem_alloc, mem_free, mem_realloc};
static FT_Library library;

static FT_Library lib(void)
{
    if (!library) {
        if (FT_New_Library(&memory, &library) != 0)
            return NULL;
        FT_Add_Default_Modules(library);
    }
    return library;
}

static int is_sfnt(const unsigned char *d, size_t n)
{
    return n >= 12 && (!memcmp(d, "OTTO", 4) || !memcmp(d, "\0\1\0\0", 4) || !memcmp(d, "true", 4) ||
                       !memcmp(d, "ttcf", 4));
}

static void cat(char *dst, const char *src, size_t cap) /* strlcat */
{
    size_t n = strlen(dst);
    if (n + 1 >= cap)
        return;
    snprintf(dst + n, cap - n, "%s", src);
}

tf_font *tf_font_new(const unsigned char *data, size_t len, int face_index)
{
    if (face_index < 0 || !lib())
        return NULL;
    tf_font *f = calloc(1, sizeof *f);
    if (!f)
        return NULL;
    f->data = malloc(len ? len : 1);
    if (!f->data) {
        free(f);
        return NULL;
    }
    memcpy(f->data, data, len);
    f->len = len;
    if (FT_New_Memory_Face(library, f->data, (FT_Long)len, face_index, &f->face) != 0) {
        free(f->data);
        free(f);
        return NULL;
    }
    FT_Face face = f->face;
    f->refs = 1;
    f->index = face_index;
    f->type = is_sfnt(data, len) ? TF_SFNT : TF_OUTLINES;

    /* The name: the style alone when it begins with the family, else "family style". */
    const char *fam = face->family_name, *sty = face->style_name;
    if (!fam && !sty)
        snprintf(f->name, sizeof f->name, "(null)");
    else if (!fam)
        snprintf(f->name, sizeof f->name, "%s", sty);
    else if (!sty || strstr(sty, fam) == sty)
        snprintf(f->name, sizeof f->name, "%s", sty ? sty : fam);
    else {
        snprintf(f->name, sizeof f->name, "%s", fam);
        cat(f->name, " ", sizeof f->name);
        cat(f->name, sty, sizeof f->name);
    }

    /* Ascent and descent in em, replaced by 0.8 and -0.2 when implausible (more than 8 em up, 3 em down). */
    int upm = face->units_per_EM;
    if (face->ascender <= 0 || face->ascender > 8 * upm)
        f->ascender = 0.8f;
    else
        f->ascender = (float)face->ascender / upm;
    if (face->descender < -3 * upm || face->descender > 3 * upm)
        f->descender = -0.2f;
    else {
        f->descender = (float)face->descender / upm;
        if (f->descender > 0)
            f->descender = -f->descender;
    }

    /* TeXpresso's resource manager selects the Adobe custom charmap (platform 7, encoding 2) when there is one. */
    for (int i = 0; i < face->num_charmaps; i++) {
        FT_CharMap cm = face->charmaps[i];
        if (cm->platform_id == 7 && cm->encoding_id == 2)
            FT_Set_Charmap(face, cm);
    }
    return f;
}

tf_font *tf_font_keep(tf_font *f)
{
    if (f)
        f->refs++;
    return f;
}

void tf_font_drop(tf_font *f)
{
    if (!f || --f->refs > 0)
        return;
    FT_Done_Face(f->face);
    free(f->data);
    free(f);
}

int tf_font_type(const tf_font *f) { return f->type; }
const char *tf_font_name(const tf_font *f) { return f ? f->name : ""; }
float tf_font_ascender(const tf_font *f) { return f->ascender; }
float tf_font_descender(const tf_font *f) { return f->descender; }

/* ---- sfnt files on disk ---- */

static uint64_t written[1024];
static int nwritten;

int tf_font_sfnt_file(tf_font *f, char *path, size_t cap, int *index)
{
    if (f->type != TF_SFNT)
        return -1;
    if (index)
        *index = f->index & 0xffff;
    if (f->written) {
        snprintf(path, cap, "%s", f->path);
        return 0;
    }
    uint64_t h = 1469598103934665603ULL; /* FNV-1a of the bytes, as dlist.c named them */
    for (size_t i = 0; i < f->len; i++) {
        h ^= f->data[i];
        h *= 1099511628211ULL;
    }
    const char *tmp = getenv("TMPDIR");
    char dir[1024];
    snprintf(dir, sizeof dir, "%s/taudot-fonts", tmp && tmp[0] ? tmp : "/tmp");
    const unsigned char *d = f->data;
    int ttc = !memcmp(d, "ttcf", 4), ttf = !memcmp(d, "\0\1\0\0", 4) || !memcmp(d, "true", 4);
    snprintf(f->path, sizeof f->path, "%s/%016llx.%s", dir, (unsigned long long)h, ttc ? "ttc" : ttf ? "ttf" : "otf");
    int known = 0;
    for (int i = 0; i < nwritten; i++)
        if (written[i] == h)
            known = 1;
    struct stat s;
    if (!known && (stat(f->path, &s) != 0 || s.st_size != (off_t)f->len)) {
        mkdir(dir, 0755);
        char part[1200];
        snprintf(part, sizeof part, "%s.%d.part", f->path, (int)getpid());
        FILE *o = fopen(part, "wb");
        if (!o)
            return -1;
        int ok = fwrite(f->data, 1, f->len, o) == f->len;
        ok = fclose(o) == 0 && ok;
        if (!ok || rename(part, f->path) != 0) {
            unlink(part);
            return -1;
        }
    }
    if (!known && nwritten < 1024)
        written[nwritten++] = h;
    f->written = 1;
    snprintf(path, cap, "%s", f->path);
    return 0;
}

/* ---- encoding ---- */

int tf_encode_char(tf_font *f, int code)
{
    return (int)FT_Get_Char_Index(f->face, (FT_ULong)code);
}

static int char_index_fallback(FT_Face face, int cid)
{
    int gid = FT_Get_Char_Index(face, cid);
    if (gid == 0)
        gid = FT_Get_Char_Index(face, 0xf000 + cid); /* symbol fonts map their codes at U+F0xx */
    if (gid == 0 && cid == 0x22ef)
        gid = FT_Get_Char_Index(face, 0x2026); /* midline ellipsis drawn as the ellipsis */
    return gid;
}

const char *const *tf__dup_names(int ucs); /* glyphlists.c */

int tf_encode_glyph_name(tf_font *f, const char *name)
{
    FT_Face face = f->face;
    int gid = FT_Get_Name_Index(face, (FT_String *)name);
    if (gid == 0) {
        /* other names the glyph lists give the same character, then uniXXXX */
        int u = tf_unicode_from_glyph_name(name);
        if (u) {
            for (const char *const *d = tf__dup_names(u); *d && !gid; d++)
                gid = FT_Get_Name_Index(face, (FT_String *)*d);
            if (!gid) {
                char buf[16];
                snprintf(buf, sizeof buf, "uni%04X", u);
                gid = FT_Get_Name_Index(face, buf);
            }
        }
    }
    if (gid == 0)
        gid = char_index_fallback(face, tf_unicode_from_glyph_name(name));
    return gid;
}

/* ---- glyphs ---- */

float tf_glyph_advance(tf_font *f, int gid, int wmode)
{
    if (gid < 0)
        return 0;
    FT_Fixed adv = 0;
    FT_Int32 mask = FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING | FT_LOAD_IGNORE_TRANSFORM;
    if (wmode)
        mask |= FT_LOAD_VERTICAL_LAYOUT;
    FT_Get_Advance(f->face, gid, mask, &adv);
    return (float)adv / f->face->units_per_EM;
}

/* A path builder with the same rules as the reference (MuPDF's fz_path, as walked into TDL), so the commands come
 * out identical, not just the shape: a moveto right after a moveto replaces it; a lineto to the current point is
 * dropped unless it follows a moveto; quadratic and cubic segments whose control points sit on their ends become
 * lines (or are dropped); a close after a close does nothing. FreeType closes each contour with an explicit segment
 * back to its start; only the last contour gets a 'Z'. */
typedef struct {
    tf_path *p;
    size_t capc, capv;
    int fail;
    int pending_move;    /* no moveto yet */
    char last;           /* last command: 0, 'M', 'L', 'Q', 'C' */
    int closed;          /* ... followed by a close */
    float cx, cy, bx, by; /* current point, start of the contour */
} sink;

static void put_cmd(sink *s, char c, const float *v, int n)
{
    tf_path *p = s->p;
    if (p->ncmd == s->capc) {
        s->capc = s->capc ? s->capc * 2 : 32;
        uint8_t *nc = realloc(p->cmd, s->capc);
        if (!nc) { s->fail = 1; return; }
        p->cmd = nc;
    }
    if (p->ncoord + n > s->capv) {
        while (p->ncoord + n > s->capv)
            s->capv = s->capv ? s->capv * 2 : 128;
        float *nv = realloc(p->coord, s->capv * sizeof(float));
        if (!nv) { s->fail = 1; return; }
        p->coord = nv;
    }
    p->cmd[p->ncmd++] = (uint8_t)c;
    for (int i = 0; i < n; i++)
        p->coord[p->ncoord++] = v[i];
}

static int after_move(const sink *s) { return s->last == 'M' && !s->closed; }

static void p_move(sink *s, float x, float y)
{
    if (after_move(s)) {
        s->p->coord[s->p->ncoord - 2] = x;
        s->p->coord[s->p->ncoord - 1] = y;
    } else {
        float v[2] = {x, y};
        put_cmd(s, 'M', v, 2);
    }
    s->last = 'M';
    s->closed = 0;
    s->cx = s->bx = x;
    s->cy = s->by = y;
}

static void p_line(sink *s, float x, float y)
{
    if (s->p->ncmd == 0)
        return;
    if (!after_move(s) && x == s->cx && y == s->cy)
        return;
    float v[2] = {x, y};
    put_cmd(s, 'L', v, 2);
    s->last = 'L';
    s->closed = 0;
    s->cx = x;
    s->cy = y;
}

static void p_quad(sink *s, float x1, float y1, float x2, float y2)
{
    if (s->p->ncmd == 0)
        return;
    if ((s->cx == x1 && s->cy == y1) || (x1 == x2 && y1 == y2)) {
        if (s->cx == x2 && s->cy == y2 && !after_move(s))
            return;
        p_line(s, x2, y2);
        return;
    }
    float v[4] = {x1, y1, x2, y2};
    put_cmd(s, 'Q', v, 4);
    s->last = 'Q';
    s->closed = 0;
    s->cx = x2;
    s->cy = y2;
}

static void p_cubic(sink *s, float x1, float y1, float x2, float y2, float x3, float y3)
{
    if (s->p->ncmd == 0)
        return;
    if (s->cx == x1 && s->cy == y1) {
        if (x2 == x3 && y2 == y3) {
            if (x1 == x2 && y1 == y2 && !after_move(s))
                return;
            p_line(s, x3, y3);
            return;
        }
        if (x1 == x2 && y1 == y2) {
            p_line(s, x3, y3);
            return;
        }
    } else if (x2 == x3 && y2 == y3) {
        if (x1 == x2 && y1 == y2) {
            p_line(s, x3, y3);
            return;
        }
    }
    float v[6] = {x1, y1, x2, y2, x3, y3};
    put_cmd(s, 'C', v, 6);
    s->last = 'C';
    s->closed = 0;
    s->cx = x3;
    s->cy = y3;
}

static void p_close(sink *s)
{
    if (s->p->ncmd == 0 || s->closed)
        return;
    put_cmd(s, 'Z', NULL, 0);
    s->closed = 1;
    s->cx = s->bx;
    s->cy = s->by;
}

/* Outlines are loaded at 65536 units per em (hinting allowed at that size) and scaled to em: exact in float. */
#define SCALE 65536
static float em(FT_Pos v) { return (float)v * (1.0f / SCALE); }

static void ensure_move(sink *s)
{
    if (s->pending_move) {
        s->pending_move = 0;
        p_move(s, 0, 0);
    }
}

static int o_move(const FT_Vector *to, void *u)
{
    sink *s = u;
    s->pending_move = 0;
    p_move(s, em(to->x), em(to->y));
    return s->fail;
}

static int o_line(const FT_Vector *to, void *u)
{
    sink *s = u;
    ensure_move(s);
    p_line(s, em(to->x), em(to->y));
    return s->fail;
}

static int o_conic(const FT_Vector *c, const FT_Vector *to, void *u)
{
    sink *s = u;
    ensure_move(s);
    p_quad(s, em(c->x), em(c->y), em(to->x), em(to->y));
    return s->fail;
}

static int o_cubic(const FT_Vector *c1, const FT_Vector *c2, const FT_Vector *to, void *u)
{
    sink *s = u;
    ensure_move(s);
    p_cubic(s, em(c1->x), em(c1->y), em(c2->x), em(c2->y), em(to->x), em(to->y));
    return s->fail;
}

static const FT_Outline_Funcs funcs = {o_move, o_line, o_conic, o_cubic, 0, 0};

int tf_glyph_outline(tf_font *f, int gid, tf_path *out)
{
    memset(out, 0, sizeof *out);
    FT_Face face = f->face;
    FT_Set_Char_Size(face, SCALE, SCALE, 72, 72);
    if (FT_Load_Glyph(face, gid, FT_LOAD_IGNORE_TRANSFORM) != 0 &&
        FT_Load_Glyph(face, gid, FT_LOAD_IGNORE_TRANSFORM | FT_LOAD_NO_HINTING) != 0)
        return -1;
    if (face->glyph->format != FT_GLYPH_FORMAT_OUTLINE)
        return -1;
    sink s;
    memset(&s, 0, sizeof s);
    s.p = out;
    s.pending_move = 1;
    if (FT_Outline_Decompose(&face->glyph->outline, &funcs, &s) != 0 || s.fail) {
        tf_path_free(out);
        return -1;
    }
    if (!s.pending_move)
        p_close(&s);
    return s.fail ? -1 : 0;
}

void tf_path_free(tf_path *p)
{
    free(p->cmd);
    free(p->coord);
    memset(p, 0, sizeof *p);
}

int tf_glyph_bounds(tf_font *f, int gid, float r[4])
{
    tf_path p;
    if (tf_glyph_outline(f, gid, &p) != 0)
        return 0;
    int have = 0;
    for (uint32_t i = 0; i + 1 < p.ncoord; i += 2) {
        float x = p.coord[i], y = p.coord[i + 1];
        if (!have) {
            r[0] = r[2] = x;
            r[1] = r[3] = y;
            have = 1;
        } else {
            if (x < r[0]) r[0] = x;
            if (y < r[1]) r[1] = y;
            if (x > r[2]) r[2] = x;
            if (y > r[3]) r[3] = y;
        }
    }
    tf_path_free(&p);
    return have;
}

int tf_glyph_name(tf_font *f, int gid, char *buf, size_t cap)
{
    if (cap == 0)
        return -1;
    buf[0] = 0;
    if (FT_HAS_GLYPH_NAMES(f->face)) {
        if (FT_Get_Glyph_Name(f->face, gid, buf, (FT_UInt)cap) != 0)
            return -1;
    } else
        snprintf(buf, cap, "%d", gid);
    return 0;
}

/* ---- text ---- */

static int utf8_put(char *s, int c)
{
    if (c < 0x80) { s[0] = c; return 1; }
    if (c < 0x800) { s[0] = 0xc0 | (c >> 6); s[1] = 0x80 | (c & 0x3f); return 2; }
    if (c < 0x10000) { s[0] = 0xe0 | (c >> 12); s[1] = 0x80 | ((c >> 6) & 0x3f); s[2] = 0x80 | (c & 0x3f); return 3; }
    s[0] = 0xf0 | (c >> 18); s[1] = 0x80 | ((c >> 12) & 0x3f); s[2] = 0x80 | ((c >> 6) & 0x3f); s[3] = 0x80 | (c & 0x3f);
    return 4;
}

/* One code point → letters: Unicode's Latin ligatures and IJ come apart. */
static int put_letters(char *s, int c)
{
    static const char *lig[] = {"ff", "fi", "fl", "ffi", "ffl", "st", "st"};
    if (c >= 0xfb00 && c <= 0xfb06) {
        strcpy(s, lig[c - 0xfb00]);
        return (int)strlen(lig[c - 0xfb00]);
    }
    if (c == 0x132) { strcpy(s, "IJ"); return 2; }
    if (c == 0x133) { strcpy(s, "ij"); return 2; }
    return utf8_put(s, c);
}

int tf_glyph_text(tf_font *f, int gid, int ucs, char *out)
{
    char name[64] = "";
    int n = 0;
    if (gid >= 0) {
        tf_glyph_name(f, gid, name, sizeof name);
        char base[64];
        int k = 0;
        for (; name[k] && name[k] != '.' && k < 63; k++)
            base[k] = name[k];
        base[k] = 0;
        if (base[0]) {
            int c = tf_unicode_from_glyph_name(base);
            if (c > 0)
                n = put_letters(out, c);
        }
    }
    /* TeX character codes: only plain printable ASCII is trustworthy (OT1 puts ligatures and accents below 0x20
     * and quotes at 0x27/0x60) */
    if (!n && ucs > 0x20 && ucs < 0x7f && ucs != 0x27 && ucs != 0x60)
        n = utf8_put(out, ucs);
    if (!n)
        n = utf8_put(out, 0xfffd);
    out[n] = 0;
    return n;
}
