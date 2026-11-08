/* taudot_font.h: TeX's fonts without MuPDF, for txp-render's interpreter and its display list (TDL).
 *
 * Copyright (c) 2026 the Taudot authors. MIT License (see LICENSE in this folder).
 *
 * Fonts are opened with FreeType (FreeType Project License; credit in the app's notices). Every answer matches
 * what MuPDF 1.28 gave for the same font (fz_new_font_from_buffer and friends), checked by tests/compare.c.
 *
 * Single-threaded. Functions return codes; nothing longjmps. Agreed with the interp agent (Phase B, step 4).
 */

#ifndef TAUDOT_FONT_H
#define TAUDOT_FONT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tf_font tf_font;

enum { TF_SFNT = 1, TF_OUTLINES = 2 }; /* = the TDL FONT record's type */

/* A TDL path: cmd is 'M' (2 coords), 'L' (2), 'Q' (4), 'C' (6) or 'Z' (0). */
typedef struct {
    uint32_t ncmd, ncoord;
    uint8_t *cmd;
    float *coord;
} tf_path;

/* Opens face `face_index` of a font file (OpenType/TrueType/collection, Type 1 .pfb/.pfa, bare CFF). The bytes are
 * copied. Selects the Adobe custom charmap when the font has one, as TeXpresso's resource manager does. NULL if
 * FreeType can't open it. Starts with one reference. */
tf_font *tf_font_new(const unsigned char *data, size_t len, int face_index);
tf_font *tf_font_keep(tf_font *f);
void tf_font_drop(tf_font *f);

int tf_font_type(const tf_font *f);                 /* TF_SFNT or TF_OUTLINES (by the file's magic) */
const char *tf_font_name(const tf_font *f);         /* family and style, as MuPDF named it (at most 31 bytes) */
float tf_font_ascender(const tf_font *f);           /* em; 0.8 when the font's is untrustworthy */
float tf_font_descender(const tf_font *f);          /* em, negative; -0.2 when untrustworthy */

/* For TF_SFNT: the file as $TMPDIR/taudot-fonts/<hash>.<otf|ttf|ttc>, written once per process (by content, so it
 * survives across runs), and the face index. 0 on success. */
int tf_font_sfnt_file(tf_font *f, char *path, size_t cap, int *index);

int tf_encode_char(tf_font *f, int code);                  /* glyph for a character code in the selected charmap */
int tf_encode_glyph_name(tf_font *f, const char *name);    /* glyph by name, with MuPDF's fallbacks; 0 if none */

float tf_glyph_advance(tf_font *f, int gid, int wmode);    /* em */
int tf_glyph_outline(tf_font *f, int gid, tf_path *out);   /* em, y up; 0 on success (empty glyphs give 0 cmds) */
void tf_path_free(tf_path *p);
int tf_glyph_bounds(tf_font *f, int gid, float r[4]);      /* em, the outline's points' bounds; 0 if no outline */
int tf_glyph_name(tf_font *f, int gid, char *buf, size_t cap); /* the font's name for it, else its number */

/* Glyph names → Unicode come from the Adobe Glyph List and TeX's extensions to it, which the caller reads from the
 * TeX bundle (glyphlist.txt, texglyphlist.txt) and hands over once; neither is compiled in. Without them, only the
 * uniXXXX/uXXXX/... forms are understood. Both files may be NULL. */
void tf_glyph_lists(const char *agl, size_t agl_len, const char *tex, size_t tex_len);
int tf_unicode_from_glyph_name(const char *name);  /* U+FFFD when unknown */

/* A glyph's text, as the glyphs verb and TDL give it: from its name (ligatures come apart: "ffi"), else from `ucs`
 * when it's plain printable ASCII (TeX character codes), else U+FFFD. UTF-8, NUL-terminated; out has >= 80 bytes. */
int tf_glyph_text(tf_font *f, int gid, int ucs, char *out);

#ifdef __cplusplus
}
#endif

#endif
