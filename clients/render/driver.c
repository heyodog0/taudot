// txp-headless: TeXpresso's incremental LaTeX engine without its window, for the taudot preview.
// (clients/render/driver.c: txp-render's copy of clients/preview/texpresso/txp-headless.c at c58b62f; dvi/README.md.)
//
// Links TeXpresso's frontend objects (github.com/let-def/texpresso, MIT, Copyright (c) 2023 Frédéric Bour) except
// its SDL window (main.c, driver.c, renderer.c). The byte-change code in `apply_change` follows TeXpresso's
// `realize_change` (main.c). Build: ./build.sh (needs a built clone, TEXPRESSO_DIR).
//
//   txp-headless [-tectonic|-texlive] [-trace] DIR/main.tex
//
// stdin: one JSON array per line.
//   TeXpresso's editor commands, unchanged: ["open", path, text], ["change", path, byte_offset, byte_len, text],
//   ["close", path], ["rescan"], ["rerun", true]...
//   ["goal", page]        typeset at least up to this 0-based page first (the last page in view); -1 = all
//   ["render", id, page, scale, x, y, w, h, rgb_path, z_path]
//                         draw a w×h pixel rect at (x, y) of the page at `scale` × PDF points into raw RGB (and zlib
//                         for Kitty's o=z if z_path isn't ""); answers like render/pdfrender.
//   ["synctex", id, path] write the SyncTeX data so far to path (plain text, SyncTeX 1)
//   ["page-style", s]     "white" (default), "sepia" or "dark": how later renders are coloured (figures kept)
// TeX also sees tu<fam>.fd files from memory for the PostScript families (TeX Gyre stand-ins; "font stand-ins").
// stdout: JSON objects, one per line (TeXpresso's own editor messages are JSON arrays and go to stderr):
//   {"id":ID,"ok":true,"w":W,"h":H,"cpu_us":N}                   render done
//   {"ev":"pages","gen":G,"applied":A,"n":N,"done":B,"sizes":[[w,h],...],"changed":[i,...],"edit_us":E,"step_us":S}
//      at quiet points: when the goal is reached and again when the document is finished. `changed` lists pages
//      whose content differs from the last "pages" event (by a hash of the page's drawing). `edit_us` is the time
//      since the first edit applied after the previous event, `step_us` the engine time spent since then. `applied`
//      counts the open and change commands read so far: the report shows all of them.
//   {"ev":"error","line":"..."}                                  a "! ..." line from TeX's output
// stderr also gets ["bib-log", text]: BibTeX's .blg after each run of it (and the cached one at start).

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

#include <mupdf/fitz.h> // Taudot's runtime (rt/), not MuPDF

#include "driver.h"
#include "editor.h"
#include "engine.h"
#include "prot_parser.h"
#include "providers.h"
#include "vstack.h"

#ifndef XETEX_PATH
#define XETEX_PATH "texpresso-xetex"
#endif

static int64_t now_us(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}

static int64_t cpu_us(void)
{
  struct rusage r;
  getrusage(RUSAGE_SELF, &r);
  return (int64_t)r.ru_utime.tv_sec * 1000000 + r.ru_utime.tv_usec + (int64_t)r.ru_stime.tv_sec * 1000000 +
         r.ru_stime.tv_usec;
}

static FILE *out; // our JSON events (the real stdout)
static volatile sig_atomic_t quitting;
static void on_signal(int sig) { (void)sig; quitting = 1; }
static bool tracing;

static void json_str(FILE *f, const char *s, int n)
{
  fputc('"', f);
  for (int i = 0; i < n; i++)
  {
    unsigned char c = s[i];
    if (c == '"' || c == '\\') fprintf(f, "\\%c", c);
    else if (c == '\n') fputs("\\n", f);
    else if (c < 0x20) fprintf(f, "\\u%04x", c);
    else fputc(c, f);
  }
  fputc('"', f);
}

// ---- state ---------------------------------------------------------------------------------------------------------

static fz_context *ctx;
static txp_engine *eng;
static const char *doc_dir;
// what the engine was made from, to make it again (see recover_lost_start)
static char engine_path[4096];
static bool use_texlive;
static const char *doc_name;
// files the editor opened (their text lives in the engine's file entries)
#define MAX_OPEN 256
static char *open_paths[MAX_OPEN];
static int open_count;

static int goal = -1;        // page to reach first, -1: everything
static bool goal_reported;   // a "pages" event was sent for the current goal
static bool done_reported;   // ... and for the finished document
static int gen;
static int64_t first_edit_at; // 0 when no edit since the last event
static int64_t step_time;
static int edits_applied;
static int lost_starts;       // times recover_lost_start ran (reported)     // open and change commands so far (reported, so a client can tell which edits a report shows)

#define MAX_PAGES 4096
static uint64_t page_hash[MAX_PAGES];
static float page_w[MAX_PAGES], page_h[MAX_PAGES];
static int reported_pages;

// display lists of the current pages, dropped on every change
static fz_display_list *dl_cache[MAX_PAGES];
static int dl_count;

// pages from this one on were typeset again since the last report (rollback truncates the page list at once)
static int retyped_from = 0;

/** The page list is now n pages long: display lists from n on are stale, and so are their hashes. */
static void pages_truncated(int n)
{
  for (int i = n; i < dl_count; i++)
    if (dl_cache[i]) { fz_drop_display_list(ctx, dl_cache[i]); dl_cache[i] = NULL; }
  if (dl_count > n) dl_count = n;
  if (n < retyped_from) retyped_from = n;
}

static int known_pages;
/** After any engine call that can roll back (changes, convergence restarts): drop what the page list lost. */
static void sync_pages(void)
{
  int n = send(page_count, eng);
  if (n < known_pages) pages_truncated(n);
  known_pages = n;
}

// dlist.c: the page's list in Taudot's format (cached per page), and TaudotRender's tile drawer (swift/)
static bool page_tdl(int page, const unsigned char **bytes, size_t *len, uint64_t *key);
int taudot_draw_tile(const unsigned char *bytes, size_t len, uint64_t key, double scale, int x, int y, int w, int h,
                     unsigned char *rgb);

static fz_display_list *page_dl(int page)
{
  if (page < 0 || page >= MAX_PAGES || page >= send(page_count, eng)) return NULL;
  if (page >= dl_count)
  {
    for (int i = dl_count; i <= page; i++) dl_cache[i] = NULL;
    dl_count = page + 1;
  }
  if (!dl_cache[page]) dl_cache[page] = send(render_page, eng, ctx, page);
  return dl_cache[page];
}

// A hash of everything the page draws (rt/fitz.c): same glyphs, paths and positions → same hash.
static uint64_t hash_page(int page)
{
  fz_display_list *dl = page_dl(page);
  return dl ? fz_hash_display_list(ctx, dl) : 0;
}

static int unhashed_from = MAX_PAGES, early_n; // pages an early report called changed without hashing them

static void report_pages(bool done)
{
  int64_t t0 = now_us();
  int n = send(page_count, eng);
  if (n > MAX_PAGES) n = MAX_PAGES;
  gen++;
  // before the end, pages past the ones typeset again keep their old size and content: the document doesn't shrink
  int shown = done || n > reported_pages ? n : reported_pages;
  fprintf(out, "{\"ev\":\"pages\",\"gen\":%d,\"lost_starts\":%d,\"applied\":%d,\"n\":%d,\"typeset\":%d,\"done\":%s,\"sizes\":[", gen, lost_starts, edits_applied, shown, n,
          done ? "true" : "false");
  for (int i = 0; i < shown; i++)
  {
    if (i < n)
    {
      fz_display_list *dl = page_dl(i);
      fz_rect r = dl ? fz_bound_display_list(ctx, dl) : fz_empty_rect;
      page_w[i] = r.x1 - r.x0;
      page_h[i] = r.y1 - r.y0;
    }
    fprintf(out, "%s[%.3f,%.3f]", i ? "," : "", page_w[i], page_h[i]);
  }
  fprintf(out, "],\"changed\":[");
  int k = 0;
  int hashed = 0;
  if (!done)
  {
    // early report, on the latency path: the last page typeset (the one TeX stopped at, usually the edit's) counts
    // as changed without hashing (~8 ms a page). The pages before it that TeX typeset again on the way there (the
    // rollback goes back to the last snapshot, often on the page before) are hashed and reported only if they
    // differ: typing on page 33 would otherwise redraw page 32 on every key (the pdf agent's perf work: ~4 tiles a
    // page a key, half the renders while typing).
    int unhashed_kept = unhashed_from < retyped_from ? unhashed_from : MAX_PAGES; // earlier early pages not retyped
    for (int i = retyped_from; i < n; i++)
    {
      if (i < n - 1 && i < reported_pages)
      {
        uint64_t h = hash_page(i);
        hashed++;
        bool same = h == page_hash[i];
        page_hash[i] = h;
        if (same) continue;
      }
      fprintf(out, "%s%d", k++ ? "," : "", i);
    }
    // only the unhashed last page (and earlier early ones not typeset again) wait for the done report's hashing
    unhashed_from = unhashed_kept < n - 1 ? unhashed_kept : n - 1;
    if (n > early_n) early_n = n;
  }
  else
  {
    int from = retyped_from < unhashed_from ? retyped_from : unhashed_from;
    for (int i = from; i < n; i++)
    {
      uint64_t h = hash_page(i);
      hashed++;
      // already reported by the early report and not typeset again since: only the baseline hash is updated
      bool early = i >= unhashed_from && i < early_n && i < retyped_from;
      if (!early && (i >= reported_pages || h != page_hash[i]))
        fprintf(out, "%s%d", k++ ? "," : "", i);
      page_hash[i] = h;
    }
    unhashed_from = MAX_PAGES;
    early_n = 0;
  }
  retyped_from = done ? MAX_PAGES : n; // pages before n are final until the next edit
  reported_pages = shown;
  fprintf(out, "],\"hashed\":%d,\"edit_us\":%lld,\"step_us\":%lld,\"report_us\":%lld}\n", hashed,
          first_edit_at ? (long long)(now_us() - first_edit_at) : -1LL, (long long)step_time,
          (long long)(now_us() - t0));
  fflush(out);
  if (done)
  {
    first_edit_at = 0;
    step_time = 0;
  }
}

// ---- commands ------------------------------------------------------------------------------------------------------

static void remember_open(const char *path, bool open)
{
  for (int i = 0; i < open_count; i++)
    if (strcmp(open_paths[i], path) == 0)
    {
      if (!open) { free(open_paths[i]); open_paths[i] = open_paths[--open_count]; }
      return;
    }
  if (open && open_count < MAX_OPEN) open_paths[open_count++] = strdup(path);
}

static void apply_open(const char *path, const char *data, int size)
{
  fileentry_t *e = send(find_file, eng, ctx, path);
  if (!e) { fprintf(stderr, "[headless] open %s: not found\n", path); return; }
  remember_open(path, true);
  int changed = -1;
  if (e->edit_data)
  {
    fz_buffer *b = e->edit_data;
    int i = 0, len = (int)b->len < size ? (int)b->len : size;
    while (i < len && b->data[i] == (unsigned char)data[i]) i++;
    changed = (i == (int)b->len && i == size) ? -1 : i;
    if ((int)b->cap < size) fz_resize_buffer(ctx, b, size + 128);
    b->len = size;
    memcpy(b->data, data, size);
  }
  else
  {
    e->edit_data = fz_new_buffer_from_copied_data(ctx, (const unsigned char *)data, size);
    if (e->fs_data)
    {
      int i = 0, len = (int)e->fs_data->len < size ? (int)e->fs_data->len : size;
      while (i < len && e->fs_data->data[i] == (unsigned char)data[i]) i++;
      changed = (i == (int)e->fs_data->len && i == size) ? -1 : i;
    }
    else if (e->seen >= 0)
      changed = 0;
  }
  if (changed >= 0) send(notify_file_changes, eng, ctx, e, changed);
}

static void apply_change(const char *path, int offset, int remove, const char *data, int length)
{
  fileentry_t *e = send(find_file, eng, ctx, path);
  if (!e || !e->edit_data) { fprintf(stderr, "[headless] change %s: not opened\n", path); return; }
  fz_buffer *b = e->edit_data;
  if (remove < 0 || offset < 0 || offset + remove > (int)b->len)
  {
    fprintf(stderr, "[headless] change %s: bad range %d+%d of %d\n", path, offset, remove, (int)b->len);
    return;
  }
  if (b->len - remove + length > b->cap) fz_resize_buffer(ctx, b, b->len - remove + length + 128);
  memmove(b->data + offset + length, b->data + offset + remove, b->len - offset - remove);
  b->len = b->len - remove + length;
  memcpy(b->data + offset, data, length);
  if (tracing) fprintf(stderr, "[headless] change %s at %d: seen %d, fs_data %d, status %d\n", path, offset, e->seen, e->fs_data ? (int)e->fs_data->len : -1, send(get_status, eng));
  send(notify_file_changes, eng, ctx, e, offset);
}

static void apply_close(const char *path)
{
  remember_open(path, false);
  fileentry_t *e = send(find_file, eng, ctx, path);
  if (!e || !e->edit_data) return;
  int changed = 0;
  if (e->fs_data)
  {
    int i = 0, len = e->fs_data->len < e->edit_data->len ? e->fs_data->len : e->edit_data->len;
    while (i < len && e->fs_data->data[i] == e->edit_data->data[i]) i++;
    changed = i;
  }
  fz_drop_buffer(ctx, e->edit_data);
  e->edit_data = NULL;
  send(notify_file_changes, eng, ctx, e, changed);
}

// ---- page style: white, sepia, dark ---------------------------------------------------------------------------------
//
// TeXpresso ignores \pagecolor, and the reader's choice of page (Settings ▸ PDF) is the reader's, not the document's:
// renders are recoloured after drawing. ["page-style", "white"|"sepia"|"dark"] sets it for the next renders.
//   dark   lightness inverted with hue and saturation kept (c + 1 - max - min: black text → light, a red link stays
//          red), then mapped onto a dark page (#1d1f21) and light ink (#d6d8da)
//   sepia  multiplied by #f4ecd8 (paper; ink stays dark)
// Figures stay as they are: raster images, and everything drawn inside a clip (included PDF/EPS figures; the cursor
// agent's glyphs call it c > 0), found once per page by a pass of its display list through a small device.

static int page_style;  // 0 white, 1 sepia, 2 dark

#define MAX_FIGS 256
typedef struct { fz_rect r[MAX_FIGS]; int n; } fig_rects;

typedef struct
{
  fz_device super;
  fig_rects *out;
  int depth;
  fz_rect clip, drawn;  // the outermost clip and what was drawn inside it
} fig_device;

static void fig_add(fig_rects *f, fz_rect r)
{
  if (fz_is_empty_rect(r) || f->n >= MAX_FIGS) return;
  f->r[f->n++] = r;
}

static void fig_drew(fz_context *c, fig_device *d, fz_rect r)
{
  (void)c;
  if (d->depth > 0) d->drawn = fz_union_rect(d->drawn, r);
}

static void fig_push(fz_context *c, fig_device *d, fz_rect r)
{
  (void)c;
  if (d->depth++ == 0) { d->clip = r; d->drawn = fz_empty_rect; }
}

static void fig_fill_path(fz_context *c, fz_device *dev, const fz_path *p, int eo, fz_matrix m, fz_colorspace *cs, const float *col, float a, fz_color_params cp)
{ fig_drew(c, (fig_device *)dev, fz_bound_path(c, p, NULL, m)); }
static void fig_stroke_path(fz_context *c, fz_device *dev, const fz_path *p, const fz_stroke_state *s, fz_matrix m, fz_colorspace *cs, const float *col, float a, fz_color_params cp)
{ fig_drew(c, (fig_device *)dev, fz_bound_path(c, p, s, m)); }
static void fig_fill_text(fz_context *c, fz_device *dev, const fz_text *t, fz_matrix m, fz_colorspace *cs, const float *col, float a, fz_color_params cp)
{ fig_drew(c, (fig_device *)dev, fz_bound_text(c, t, NULL, m)); }
static void fig_stroke_text(fz_context *c, fz_device *dev, const fz_text *t, const fz_stroke_state *s, fz_matrix m, fz_colorspace *cs, const float *col, float a, fz_color_params cp)
{ fig_drew(c, (fig_device *)dev, fz_bound_text(c, t, s, m)); }
static void fig_fill_shade(fz_context *c, fz_device *dev, fz_shade *sh, fz_matrix m, float a, fz_color_params cp)
{ fig_drew(c, (fig_device *)dev, fz_bound_shade(c, sh, m)); }
static void fig_fill_image(fz_context *c, fz_device *dev, fz_image *img, fz_matrix m, float a, fz_color_params cp)
{
  fig_device *d = (fig_device *)dev;
  fz_rect r = fz_transform_rect(fz_unit_rect, m);
  if (d->depth > 0) fig_drew(c, d, r);
  else fig_add(d->out, r);  // a raster image on the page itself
}
static void fig_fill_image_mask(fz_context *c, fz_device *dev, fz_image *img, fz_matrix m, fz_colorspace *cs, const float *col, float a, fz_color_params cp)
{ fig_drew(c, (fig_device *)dev, fz_transform_rect(fz_unit_rect, m)); }
static void fig_clip_path(fz_context *c, fz_device *dev, const fz_path *p, int eo, fz_matrix m, fz_rect sc)
{ fig_push(c, (fig_device *)dev, fz_bound_path(c, p, NULL, m)); }
static void fig_clip_stroke_path(fz_context *c, fz_device *dev, const fz_path *p, const fz_stroke_state *s, fz_matrix m, fz_rect sc)
{ fig_push(c, (fig_device *)dev, fz_bound_path(c, p, s, m)); }
static void fig_clip_text(fz_context *c, fz_device *dev, const fz_text *t, fz_matrix m, fz_rect sc)
{ fig_push(c, (fig_device *)dev, fz_bound_text(c, t, NULL, m)); }
static void fig_clip_stroke_text(fz_context *c, fz_device *dev, const fz_text *t, const fz_stroke_state *s, fz_matrix m, fz_rect sc)
{ fig_push(c, (fig_device *)dev, fz_bound_text(c, t, s, m)); }
static void fig_clip_image_mask(fz_context *c, fz_device *dev, fz_image *img, fz_matrix m, fz_rect sc)
{ fig_push(c, (fig_device *)dev, fz_transform_rect(fz_unit_rect, m)); }
static void fig_pop_clip(fz_context *c, fz_device *dev)
{
  fig_device *d = (fig_device *)dev;
  if (d->depth > 0 && --d->depth == 0) fig_add(d->out, fz_intersect_rect(d->clip, d->drawn));
}

// per page: the display list the rects were found in (kept, so its address can't come back for another page)
static fz_display_list *fig_dl[MAX_PAGES];
static fig_rects *fig_cache[MAX_PAGES];

/** The page's figure rects, in display-list space. */
static fig_rects *page_figures(int page, fz_display_list *dl)
{
  if (fig_dl[page] == dl && fig_cache[page]) return fig_cache[page];
  if (fig_dl[page]) fz_drop_display_list(ctx, fig_dl[page]);
  fig_dl[page] = fz_keep_display_list(ctx, dl);
  if (!fig_cache[page]) fig_cache[page] = malloc(sizeof(fig_rects));
  fig_rects *f = fig_cache[page];
  f->n = 0;
  fig_device *d = fz_new_derived_device(ctx, fig_device);
  d->out = f;
  d->super.fill_path = fig_fill_path;
  d->super.stroke_path = fig_stroke_path;
  d->super.fill_text = fig_fill_text;
  d->super.stroke_text = fig_stroke_text;
  d->super.fill_shade = fig_fill_shade;
  d->super.fill_image = fig_fill_image;
  d->super.fill_image_mask = fig_fill_image_mask;
  d->super.clip_path = fig_clip_path;
  d->super.clip_stroke_path = fig_clip_stroke_path;
  d->super.clip_text = fig_clip_text;
  d->super.clip_stroke_text = fig_clip_stroke_text;
  d->super.clip_image_mask = fig_clip_image_mask;
  d->super.pop_clip = fig_pop_clip;
  fz_try(ctx)
  {
    fz_run_display_list(ctx, dl, &d->super, fz_identity, fz_infinite_rect, NULL);
    fz_close_device(ctx, &d->super);
  }
  fz_always(ctx) fz_drop_device(ctx, &d->super);
  fz_catch(ctx) f->n = 0;
  return f;
}

/** Recolours a rendered pixmap (RGB, pixel box `box`, drawn with `m` from display-list space) for the page style. */
static void restyle(unsigned char *s, int stride, fz_irect box, int page, fz_display_list *dl, fz_matrix m)
{
  if (!page_style) return;
  fig_rects *f = page_figures(page, dl);
  // the figures in this pixmap's pixels
  fz_irect keep[MAX_FIGS];
  int nk = 0;
  for (int i = 0; i < f->n; i++)
  {
    fz_irect r = fz_intersect_irect(fz_round_rect(fz_transform_rect(f->r[i], m)), box);
    if (!fz_is_empty_irect(r)) keep[nk++] = r;
  }
  int w = box.x1 - box.x0, h = box.y1 - box.y0;
  static const int bg[3] = {0x1d, 0x1f, 0x21}, fg[3] = {0xd6, 0xd8, 0xda}, sepia[3] = {0xf4, 0xec, 0xd8};
  for (int y = 0; y < h; y++)
  {
    unsigned char *row = s + (size_t)y * stride;
    int py = box.y0 + y;
    for (int x = 0; x < w; x++)
    {
      int px = box.x0 + x;
      bool fig = false;
      for (int k = 0; k < nk && !fig; k++)
        fig = px >= keep[k].x0 && px < keep[k].x1 && py >= keep[k].y0 && py < keep[k].y1;
      if (fig) continue;
      unsigned char *p = row + x * 3;
      if (page_style == 1)
      {
        for (int c = 0; c < 3; c++) p[c] = (unsigned char)((p[c] * sepia[c] + 127) / 255);
        continue;
      }
      int r = p[0], g = p[1], b = p[2];
      int mx = r > g ? (r > b ? r : b) : (g > b ? g : b), mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
      int d = 255 - mx - mn;
      int v[3] = {r + d, g + d, b + d};
      for (int c = 0; c < 3; c++) p[c] = (unsigned char)(bg[c] + (v[c] * (fg[c] - bg[c]) + 127) / 255);
    }
  }
}

static void cmd_render(vstack *st, val cmd)
{
  int n = val_array_length(ctx, st, cmd);
  if (n != 10) { fprintf(out, "{\"ok\":false,\"error\":\"render takes 9 arguments\"}\n"); return; }
  double id = val_number(ctx, val_array_get(ctx, st, cmd, 1));
  int page = val_number(ctx, val_array_get(ctx, st, cmd, 2));
  float scale = val_number(ctx, val_array_get(ctx, st, cmd, 3));
  int x = val_number(ctx, val_array_get(ctx, st, cmd, 4));
  int y = val_number(ctx, val_array_get(ctx, st, cmd, 5));
  int w = val_number(ctx, val_array_get(ctx, st, cmd, 6));
  int h = val_number(ctx, val_array_get(ctx, st, cmd, 7));
  const char *rgb_path = val_string(ctx, st, val_array_get(ctx, st, cmd, 8));
  const char *z_path = val_string(ctx, st, val_array_get(ctx, st, cmd, 9));
  int64_t c0 = cpu_us();
  fz_display_list *dl = page_dl(page);
  if (!dl || w <= 0 || h <= 0)
  {
    fprintf(out, "{\"id\":%.0f,\"ok\":false,\"error\":\"no page %d\"}\n", id, page);
    return;
  }
  // drawn from the page's display list by TaudotRender (swift/Sources/TaudotRenderC), in this process
  fz_irect box = fz_make_irect(x, y, x + w, y + h);
  fz_rect b = fz_bound_display_list(ctx, dl);
  fz_matrix m = fz_concat(fz_translate(-b.x0, -b.y0), fz_scale(scale, scale));
  size_t size = (size_t)w * h * 3;
  unsigned char *packed = malloc(size);
  const unsigned char *tdl;
  size_t tdl_len;
  uint64_t key;
  if (!page_tdl(page, &tdl, &tdl_len, &key) || taudot_draw_tile(tdl, tdl_len, key, scale, x, y, w, h, packed) != 0)
  {
    free(packed);
    fprintf(out, "{\"id\":%.0f,\"ok\":false,\"error\":\"cannot draw page %d\"}\n", id, page);
    return;
  }
  restyle(packed, w * 3, box, page, dl, m);
  bool ok = true;
  FILE *f = fopen(rgb_path, "wb");
  if (!f || fwrite(packed, 1, size, f) != size) ok = false;
  if (f) fclose(f);
  if (ok && z_path[0])
  {
    uLongf zlen = compressBound(size);
    unsigned char *z = malloc(zlen);
    if (compress2(z, &zlen, packed, size, 1) != Z_OK) ok = false;
    else
    {
      FILE *zf = fopen(z_path, "wb");
      if (!zf || fwrite(z, 1, zlen, zf) != zlen) ok = false;
      if (zf) fclose(zf);
    }
    free(z);
  }
  free(packed);
  if (ok)
    fprintf(out, "{\"id\":%.0f,\"ok\":true,\"w\":%d,\"h\":%d,\"cpu_us\":%lld}\n", id, w, h,
            (long long)(cpu_us() - c0));
  else
    fprintf(out, "{\"id\":%.0f,\"ok\":false,\"error\":\"cannot write\"}\n", id);
}

static void cmd_synctex(double id, const char *path)
{
  fz_buffer *buf = NULL;
  send(synctex, eng, &buf);
  FILE *f = fopen(path, "wb");
  if (f)
  {
    if (buf) fwrite(buf->data, 1, buf->len, f);
    fclose(f);
  }
  fprintf(out, "{\"id\":%.0f,\"ok\":%s,\"bytes\":%d}\n", id, f ? "true" : "false", buf ? (int)buf->len : 0);
}

// aux convergence (\\ref, \\cite, TOC): like TeXpresso's own loop, re-run with the new .aux after 2 s without
// edits (a rerun starts TeX from scratch: while someone types it costs their edits time and, until its first
// snapshot, risks recover_lost_start), at most 5 times in a row; ["rerun", false] turns it off, ["rerun-once"] asks for one pass now
static bool rerun_enabled = true, rerun_once;
static int rerun_count;
static int64_t last_edit_at;
#define RERUN_IDLE_US 2000000
#define MAX_RERUNS 5

// ---- holding edits while the page in view is typeset ---------------------------------------------------------------
//
// Each edit rolls TeX back to its last snapshot before the changed byte. Typing on the first page rolls back into the
// font loading before page 1 (~100+ ms of TeX each time): keys 100-250 ms apart kill every run before it ships the
// page, and nothing is shown until the typing stops (59 s of typing, one report). So once edits are applied, later
// edits wait until the goal page has been reported (or the run ends, or HOLD_MAX_US passes), then go in together:
// every cycle shows the page with all edits made up to its start.

#define HOLD_MAX_US 1000000
typedef struct { int tag; char *path; int offset, remove, length; char *data; } held_edit;
static held_edit *held;  // grows: a replace-all is thousands of changes, and a dropped one desyncs TeX (C10)
static int held_count, held_cap;
static int64_t applied_at;  // when the edits now being typeset were applied (0: none pending)

static bool holding(void)
{
  return applied_at && !goal_reported && goal >= 0 && send(get_status, eng) == DOC_RUNNING
    && now_us() - applied_at < HOLD_MAX_US;
}

static void hold(int tag, const char *path, int offset, int remove, const char *data, int length)
{
  if (held_count == held_cap)
  {
    held_cap = held_cap ? held_cap * 2 : 256;
    held = realloc(held, held_cap * sizeof *held);
    if (!held) { perror("[headless] held edits"); exit(1); }
  }
  held_edit *h = &held[held_count++];
  h->tag = tag;
  h->path = path ? strdup(path) : NULL;
  h->offset = offset;
  h->remove = remove;
  h->length = length;
  h->data = data ? memcpy(malloc(length + 1), data, length) : NULL;
}

static void bib_check(void);

static void apply_held(void)
{
  for (int i = 0; i < held_count; i++)
  {
    held_edit *h = &held[i];
    if (h->tag == EDIT_OPEN) { edits_applied++; apply_open(h->path, h->data, h->length); }
    else if (h->tag == EDIT_CHANGE) { edits_applied++; apply_change(h->path, h->offset, h->remove, h->data, h->length); }
    else if (h->tag == EDIT_CLOSE) apply_close(h->path);
    else if (h->tag == EDIT_RESCAN) { send(detect_changes, eng, ctx); bib_check(); }
    free(h->path);
    free(h->data);
  }
  if (tracing && held_count) fprintf(stderr, "[headless] applied %d held edits\n", held_count);
  held_count = 0;
}

// TXP_EXTRA_COMMANDS: a driver that #includes this file (clients/render/txp-render.c) answers its own verbs first.
#ifdef TXP_EXTRA_COMMANDS
static bool txp_extra_command(vstack *st, val cmd, const char *verb, int n);
#endif

static void interpret(vstack *st, val cmd)
{
  if (!val_is_array(cmd) || val_array_length(ctx, st, cmd) < 1) return;
  val verb = val_array_get(ctx, st, cmd, 0);
  const char *v = val_is_string(verb) ? val_string(ctx, st, verb) : val_is_name(verb) ? val_as_name(ctx, st, verb) : "";
  int n = val_array_length(ctx, st, cmd);
#ifdef TXP_EXTRA_COMMANDS
  if (txp_extra_command(st, cmd, v, n)) return;
#endif
  if (strcmp(v, "render") == 0) { cmd_render(st, cmd); return; }
  if (strcmp(v, "goal") == 0 && n == 2)
  {
    int g = val_number(ctx, val_array_get(ctx, st, cmd, 1));
    if (g != goal) { goal = g; goal_reported = false; }
    return;
  }
  if (strcmp(v, "page-style") == 0 && n == 2)
  {
    const char *s = val_string(ctx, st, val_array_get(ctx, st, cmd, 1));
    page_style = strcmp(s, "dark") == 0 ? 2 : strcmp(s, "sepia") == 0 ? 1 : 0;
    return;
  }
  if (strcmp(v, "synctex") == 0 && n == 3)
  {
    cmd_synctex(val_number(ctx, val_array_get(ctx, st, cmd, 1)), val_string(ctx, st, val_array_get(ctx, st, cmd, 2)));
    return;
  }

  if (tracing) fprintf(stderr, "[headless] command %s\n", v);
  struct editor_command c;
  if (!editor_parse(ctx, st, cmd, &c)) return;
  int64_t t = now_us();
  switch (c.tag)
  {
    case EDIT_OPEN:
      if (held_count || holding()) hold(EDIT_OPEN, c.open.path, 0, 0, c.open.data, c.open.length);
      else { edits_applied++; apply_open(c.open.path, c.open.data, c.open.length); }
      break;
    case EDIT_CHANGE:
      if (c.change.base != BASE_BYTE) { fprintf(stderr, "[headless] only byte changes\n"); return; }
      if (held_count || holding())
        hold(EDIT_CHANGE, c.change.path, c.change.span.offset, c.change.span.remove, c.change.data, c.change.length);
      else
      {
        edits_applied++;
        apply_change(c.change.path, c.change.span.offset, c.change.span.remove, c.change.data, c.change.length);
      }
      break;
    case EDIT_CLOSE:
      if (held_count || holding()) hold(EDIT_CLOSE, c.close.path, 0, 0, NULL, 0);
      else apply_close(c.close.path);
      break;
    case EDIT_RESCAN:  // in order with held edits (C10)
      if (held_count || holding()) hold(EDIT_RESCAN, NULL, 0, 0, NULL, 0);
      else { send(detect_changes, eng, ctx); bib_check(); }
      break;
    case EDIT_RERUN:
      rerun_enabled = c.rerun.status;
      return;
    case EDIT_RERUN_ONCE:
      rerun_once = true;
      return;
    default:
      return;
  }
  if (!first_edit_at) first_edit_at = t;
  last_edit_at = t;
  rerun_count = 0;
}

// ---- lost start ----------------------------------------------------------------------------------------------------
//
// An edit that arrives before a fresh run (the first, or an aux rerun from scratch) has written its first snapshot
// makes TeXpresso kill that run's only TeX process ("worker might be stuck") and roll back to nothing ("No fences,
// assuming process finished"). It keeps the dead process as its root, and only spawns a new one when it has none, so
// it never typesets again: 0 pages, whatever is edited. After a change, a job that isn't running with no pages is that
// state (a real edit always resumes from a snapshot). The engine is made again, the editor's open files put back
// before its first TeX process starts, and typesetting starts over.

static dvi_reshooks make_hooks(void)
{
  return use_texlive ? dvi_texlive_hooks(ctx, doc_dir) : dvi_tectonic_hooks(ctx, doc_dir);
}

static bool lost_start(void)
{
  return send(get_status, eng) != DOC_RUNNING && send(page_count, eng) == 0;
}

static void recover_lost_start(void)
{
  int n = open_count;
  char *paths[MAX_OPEN];
  fz_buffer *texts[MAX_OPEN];
  for (int i = 0; i < n; i++)
  {
    fileentry_t *e = send(find_file, eng, ctx, open_paths[i]);
    paths[i] = strdup(open_paths[i]);
    texts[i] = e && e->edit_data ? fz_new_buffer_from_copied_data(ctx, e->edit_data->data, e->edit_data->len) : NULL;
  }
  fprintf(stderr, "[headless] lost start: TeXpresso has no process and no pages; starting again with %d open files\n", n);
  for (int i = 0; i < dl_count; i++)
    if (dl_cache[i]) { fz_drop_display_list(ctx, dl_cache[i]); dl_cache[i] = NULL; }
  dl_count = 0;
  known_pages = 0;
  retyped_from = 0;
  send(destroy, eng, ctx);
  eng = txp_create_tex_engine(ctx, engine_path, use_texlive, false, "", doc_name, make_hooks());
  for (int i = 0; i < open_count; i++) free(open_paths[i]);
  open_count = 0;
  send(begin_changes, eng, ctx);  // no TeX process yet: the opens only set the files' text
  for (int i = 0; i < n; i++)
  {
    if (texts[i]) { apply_open(paths[i], (const char *)texts[i]->data, (int)texts[i]->len); fz_drop_buffer(ctx, texts[i]); }
    free(paths[i]);
  }
  send(end_changes, eng, ctx);
  send(step, eng, ctx, true);
  lost_starts++;
}

static void changed(void);

// ---- bibliography --------------------------------------------------------------------------------------------------
//
// TeXpresso never runs BibTeX: a new \cite stays "?" until a .bbl appears. When a run is done, the aux's \citation,
// \bibdata and \bibstyle lines (and the .bib/.bst files' size and mtime) are compared with the last BibTeX run's; if
// they differ, Tectonic compiles a stub in a temp folder whose aux holds just those lines (Tectonic runs its own
// BibTeX on it, ~0.9 s, with the document's folder on the search path) and the .bbl it makes goes to TeXpresso as an
// open file (the document's own .bbl on disk is never written). TeX rolls back to where it read the .bbl, the aux
// gets the new \bibcite lines, and the usual aux rerun puts the numbers in. No aux rerun starts while BibTeX runs
// (it would be redone). ["rescan"] checks again (a saved .bib). $TAUDOT_BIB_CACHE=DIR keeps the last .bbl and its
// signature there, loaded before the first run. biblatex (biber) isn't handled: its aux has no \bibdata.
//   stdout: {"ev":"bib","ok":B,"ms":N,"bytes":N} when a BibTeX run ends (ms: from its start to the .bbl going in)

static char *bib_sig;            // the signature the current .bbl was made for
static char *bib_running_sig;    // the running job's
static char *bib_failed_sig;     // the input of the last job that made no .bbl: not run again until it changes (C9)
static bool bib_again;           // the signature changed while a job ran
static pid_t bib_pid;
static char bib_dir[1024];
static int64_t bib_started;
static fz_buffer *bib_ready;     // a finished job's .bbl, waiting for held edits to go in
static int bib_runs;

static bool line_starts(const unsigned char *p, const unsigned char *end, const char *s)
{
  size_t n = strlen(s);
  return (size_t)(end - p) >= n && memcmp(p, s, n) == 0;
}

static void bib_stat(fz_buffer *sig, const char *name, const char *ext)
{
  char path[1100];
  size_t n = strlen(name), e = strlen(ext);
  // `\bibliography{refs.bib}` names the file itself, as BibTeX accepts (C8)
  snprintf(path, sizeof path, "%s%s", name, n > e && !strcmp(name + n - e, ext) ? "" : ext);
  struct stat st;
  if (stat(path, &st) == 0)
    fz_append_printf(ctx, sig, "%%%s %lld %ld.%09ld\n", path, (long long)st.st_size, (long)st.st_mtimespec.tv_sec,
                     (long)st.st_mtimespec.tv_nsec);
}

/** Appends the BibTeX lines of an aux (and the aux files it \@input's) to `lines`, and their files to `files`. */
static void bib_scan(const char *aux, fz_buffer *lines, fz_buffer *files, int depth)
{
  fileentry_t *e = send(find_file, eng, ctx, aux);
  if (!e || !e->saved.data || depth > 3) return;
  const unsigned char *p = e->saved.data->data, *end = p + e->saved.data->len;
  while (p < end)
  {
    const unsigned char *nl = memchr(p, '\n', end - p);
    const unsigned char *le = nl ? nl : end;
    if (line_starts(p, le, "\\citation{") || line_starts(p, le, "\\bibdata{") || line_starts(p, le, "\\bibstyle{"))
    {
      fz_append_data(ctx, lines, p, le - p);
      fz_append_byte(ctx, lines, '\n');
      bool data = line_starts(p, le, "\\bibdata{"), style = line_starts(p, le, "\\bibstyle{");
      if (data || style)
      {
        const unsigned char *a = memchr(p, '{', le - p) + 1, *b = memchr(a, '}', le - a);
        while (b && a < b)
        {
          const unsigned char *c = memchr(a, ',', b - a);
          if (!c) c = b;
          char name[1024];
          int n = (int)(c - a) < (int)sizeof name - 1 ? (int)(c - a) : (int)sizeof name - 1;
          memcpy(name, a, n);
          name[n] = 0;
          bib_stat(files, name, data ? ".bib" : ".bst");
          a = c + 1;
        }
      }
    }
    else if (line_starts(p, le, "\\@input{"))
    {
      const unsigned char *a = p + 8, *b = memchr(a, '}', le - a);
      if (b && b - a < 1000)
      {
        char sub[1024];
        memcpy(sub, a, b - a);
        sub[b - a] = 0;
        bib_scan(sub, lines, files, depth + 1);
      }
    }
    p = le + 1;
  }
}

static void bib_aux_name(char *out, size_t size, const char *ext)
{
  const char *dot = strrchr(doc_name, '.');
  int stem = dot ? (int)(dot - doc_name) : (int)strlen(doc_name);
  snprintf(out, size, "%.*s%s", stem, doc_name, ext);
}

/** $TAUDOT_BIB_CACHE/<main's name>.bbl and .bibsig */
static void bib_cache_path(char *out, size_t size, const char *ext)
{
  char name[1024];
  bib_aux_name(name, sizeof name, ext);
  const char *dir = getenv("TAUDOT_BIB_CACHE");
  snprintf(out, size, "%s/%s", dir ? dir : "", name);
}

/** The argument of the last `\cmd{...}` in the aux lines (NUL if none). */
static void bib_arg(fz_buffer *lines, const char *cmd, char *out, size_t size)
{
  out[0] = 0;
  const char *p = (const char *)lines->data, *end = p + lines->len;
  size_t n = strlen(cmd);
  while ((p = memmem(p, end - p, cmd, n)) != NULL)
  {
    p += n;
    const char *q = memchr(p, '}', end - p);
    if (!q) break;
    snprintf(out, size, "%.*s", (int)(q - p), p);
    p = q;
  }
}

/** True when the style and every database are files in the document's folder, so TeX Live's own BibTeX ($TAUDOT_BIBTEX,
 *  0.99d: Overleaf's) can run with nothing else on its search path. Tectonic's BibTeX loses the spaces inside @STRING
 *  values ("Proc. Advances in ..." becomes "Proc.Advancesin..."), so it is only the fallback for styles that come
 *  from a TeX distribution (plainnat and the like). */
static bool bib_local(fz_buffer *lines)
{
  char style[512], data[2048], path[4200];
  bib_arg(lines, "\\bibstyle{", style, sizeof style);
  bib_arg(lines, "\\bibdata{", data, sizeof data);
  if (!style[0] || !data[0]) return false;
  struct stat st;
  snprintf(path, sizeof path, "%s/%s.bst", doc_dir, style);
  if (stat(path, &st) != 0) return false;
  for (char *save = NULL, *name = strtok_r(data, ",", &save); name; name = strtok_r(NULL, ",", &save))
  {
    while (*name == ' ') name++;
    size_t k = strlen(name);
    snprintf(path, sizeof path, "%s/%s%s", doc_dir, name, k > 4 && !strcmp(name + k - 4, ".bib") ? "" : ".bib");
    if (stat(path, &st) != 0) return false;
  }
  return true;
}

static void bib_start(fz_buffer *lines, const char *sig)
{
  const char *tmp = getenv("TMPDIR");
  snprintf(bib_dir, sizeof bib_dir, "%s/txs-bib-XXXXXX", tmp && *tmp ? tmp : "/tmp");
  if (!mkdtemp(bib_dir)) { perror("[bib] mkdtemp"); bib_dir[0] = 0; return; }
  char path[1100];
  snprintf(path, sizeof path, "%s/lines.txt", bib_dir);
  FILE *f = fopen(path, "wb");
  if (!f) return;
  fwrite(lines->data, 1, lines->len, f);
  fclose(f);
  snprintf(path, sizeof path, "%s/txs-bib.tex", bib_dir);
  f = fopen(path, "wb");
  if (!f) return;
  // the stub's aux gets the lines as they are (\readline: no expansion, no end-of-line character)
  fputs("\\documentclass{article}\\begin{document}\\makeatletter\n"
        "\\newread\\txs@in\\openin\\txs@in=lines.txt\n"
        "{\\endlinechar=-1 \\loop\\unless\\ifeof\\txs@in\\readline\\txs@in to\\txs@l"
        "\\immediate\\write\\@mainaux{\\txs@l}\\repeat}\n"
        "\\closein\\txs@in\\null\\end{document}\n", f);
  fclose(f);
  char search[4200];
  snprintf(search, sizeof search, "-Zsearch-path=%s", doc_dir);
  const char *bibtex = getenv("TAUDOT_BIBTEX");
  bool own = bibtex && *bibtex && access(bibtex, X_OK) == 0 && bib_local(lines);
  if (own)
  {
    // BibTeX reads the aux itself: the lines as they are, one per line
    snprintf(path, sizeof path, "%s/txs-bib.aux", bib_dir);
    f = fopen(path, "wb");
    if (!f) return;
    fwrite(lines->data, 1, lines->len, f);
    if (lines->len && lines->data[lines->len - 1] != '\n') fputc('\n', f);
    fclose(f);
    // absolute: BibTeX runs in bib_dir
    char abs[PATH_MAX];
    snprintf(search, sizeof search, "%s:", realpath(doc_dir, abs) ? abs : doc_dir);
  }
  bib_started = now_us();
  pid_t pid = fork();
  if (pid == 0)
  {
    setpgid(0, 0);
    if (chdir(bib_dir) != 0) _exit(127);
    int null = open("/dev/null", O_RDWR);
    dup2(null, STDIN_FILENO);
    dup2(null, STDOUT_FILENO);
    if (!tracing) dup2(null, STDERR_FILENO);
    if (own)
    {
      // only the document's folder; TeX Live's line width and limits from the texmf.cnf beside the binary
      // (clients/render/bibtex/texmf.cnf)
      char cnf[1100];
      snprintf(cnf, sizeof cnf, "%s", bibtex);
      char *slash = strrchr(cnf, '/');
      if (slash) *slash = 0;
      setenv("BIBINPUTS", search, 1);
      setenv("BSTINPUTS", search, 1);
      setenv("TEXMFCNF", slash ? cnf : ".", 1);
      execl(bibtex, bibtex, "txs-bib", (char *)NULL);  // the full path: kpathsea finds itself from argv[0]
    }
    else
      execlp("tectonic", "tectonic", "-X", "--chatter", "minimal", "compile", "-k", "--keep-logs", search, "txs-bib.tex", (char *)NULL);
    _exit(127);
  }
  if (pid < 0) { perror("[bib] fork"); return; }
  bib_pid = pid;
  free(bib_running_sig);
  bib_running_sig = strdup(sig);
  bib_runs++;
  if (tracing) fprintf(stderr, "[bib] run %d: %s in %s\n", bib_runs, own ? "bibtex" : "tectonic", bib_dir);
}

/** A run is done (or a .bib was saved): run BibTeX if its input changed since the .bbl in use was made. */
static void bib_check(void)
{
  char aux[1024];
  bib_aux_name(aux, sizeof aux, ".aux");
  fz_buffer *lines = fz_new_buffer(ctx, 1024), *files = fz_new_buffer(ctx, 256);
  bib_scan(aux, lines, files, 0);
  bool has_data = memmem(lines->data, lines->len, "\\bibdata{", 9) != NULL;
  // which BibTeX makes it is part of the signature: a .bbl cached from Tectonic's is made again by TeX Live's
  const char *bibtex = getenv("TAUDOT_BIBTEX");
  if (bibtex && *bibtex && bib_local(lines)) fz_append_string(ctx, files, "%bibtex 0.99d\n");
  fz_append_data(ctx, files, lines->data, lines->len);
  fz_terminate_buffer(ctx, files);
  const char *sig = (const char *)files->data;
  if (has_data && (!bib_sig || strcmp(sig, bib_sig) != 0) && !(bib_failed_sig && strcmp(sig, bib_failed_sig) == 0))
  {
    if (bib_pid) { if (!bib_running_sig || strcmp(sig, bib_running_sig) != 0) bib_again = true; }
    else bib_start(lines, sig);
  }
  fz_drop_buffer(ctx, lines);
  fz_drop_buffer(ctx, files);
}

static void bib_cleanup(void)
{
  if (!bib_dir[0]) return;
  static const char *names[] = {"lines.txt", "txs-bib.tex", "txs-bib.aux", "txs-bib.bbl", "txs-bib.blg",
                                "txs-bib.log", "txs-bib.pdf", "txs-bib.xdv"};
  char path[1100];
  for (size_t i = 0; i < sizeof names / sizeof *names; i++)
  {
    snprintf(path, sizeof path, "%s/%s", bib_dir, names[i]);
    unlink(path);
  }
  rmdir(bib_dir);
  bib_dir[0] = 0;
}

/** BibTeX's log (.blg) for the app's issues list, as Overleaf lists it: one stderr line ["bib-log", text]. */
static void bib_emit_log(fz_buffer *blg)
{
  if (!blg) return;
  char *mem = NULL;
  size_t len = 0;
  FILE *m = open_memstream(&mem, &len);
  if (!m) return;
  fputs("[\"bib-log\", ", m);
  json_str(m, (const char *)blg->data, (int)blg->len);
  fputs("]\n", m);
  fclose(m);
  fflush(stdout);  // TeXpresso's lines (stdio stdout, on the same fd) first
  fwrite(mem, 1, len, stderr);
  free(mem);
}

static void bib_write_blg_cache(fz_buffer *blg)
{
  if (!getenv("TAUDOT_BIB_CACHE") || !blg) return;
  char path[1100];
  bib_cache_path(path, sizeof path, ".blg");
  FILE *f = fopen(path, "wb");
  if (f) { fwrite(blg->data, 1, blg->len, f); fclose(f); }
}

static void bib_write_cache(fz_buffer *bbl, const char *sig)
{
  if (!getenv("TAUDOT_BIB_CACHE")) return;
  char path[1100];
  bib_cache_path(path, sizeof path, ".bbl");
  FILE *f = fopen(path, "wb");
  if (f) { fwrite(bbl->data, 1, bbl->len, f); fclose(f); }
  bib_cache_path(path, sizeof path, ".bibsig");
  f = fopen(path, "wb");
  if (f) { fputs(sig, f); fclose(f); }
}

/** The .bbl goes to TeXpresso as an open file: TeX rolls back to where it read it. */
static bool bib_apply(fz_buffer *bbl)
{
  char name[1024];
  bib_aux_name(name, sizeof name, ".bbl");
  send(begin_changes, eng, ctx);
  apply_open(name, (const char *)bbl->data, (int)bbl->len);
  bool ch = send(end_changes, eng, ctx);
  if (ch) changed();
  rerun_count = 0;
  return ch;
}

/** The job ended: take its .bbl (if it made one) and start again if the input changed meanwhile. */
static void bib_poll(void)
{
  if (bib_ready && !held_count && !holding())
  {
    bib_apply(bib_ready);
    fz_drop_buffer(ctx, bib_ready);
    bib_ready = NULL;
  }
  if (!bib_pid) return;
  int status;
  if (waitpid(bib_pid, &status, WNOHANG) != bib_pid) return;
  bib_pid = 0;
  char path[1100];
  snprintf(path, sizeof path, "%s/txs-bib.bbl", bib_dir);
  fz_buffer *bbl = NULL;
  struct stat st = {0};
  if (stat(path, &st) == 0 && st.st_size > 0)
  {
    fz_try(ctx) bbl = fz_read_file(ctx, path);
    fz_catch(ctx) bbl = NULL;
  }
  fz_buffer *blg = NULL;
  snprintf(path, sizeof path, "%s/txs-bib.blg", bib_dir);
  if (access(path, R_OK) == 0)
  {
    fz_try(ctx) blg = fz_read_file(ctx, path);
    fz_catch(ctx) blg = NULL;
  }
  bib_cleanup();
  bib_emit_log(blg);
  if (bbl) bib_write_blg_cache(blg);
  fz_drop_buffer(ctx, blg);
  free(bib_failed_sig);
  bib_failed_sig = NULL;
  if (!bbl)
  {
    bib_failed_sig = bib_running_sig;
    bib_running_sig = NULL;
  }
  if (bbl)
  {
    free(bib_sig);
    bib_sig = bib_running_sig;
    bib_running_sig = NULL;
    bib_write_cache(bbl, bib_sig);
    if (held_count || holding())
    {
      if (bib_ready) fz_drop_buffer(ctx, bib_ready);  // a newer .bbl replaces one still waiting (C11)
      bib_ready = bbl;
    }
    else { bib_apply(bbl); fz_drop_buffer(ctx, bbl); }
  }
  fprintf(out, "{\"ev\":\"bib\",\"ok\":%s,\"ms\":%lld,\"bytes\":%d}\n", bbl ? "true" : "false",
          (long long)((now_us() - bib_started) / 1000), (int)st.st_size);
  fflush(out);
  if (tracing) fprintf(stderr, "[bib] done (%s) in %lld ms\n", bbl ? "bbl" : "no bbl", (long long)((now_us() - bib_started) / 1000));
  if (bib_again) { bib_again = false; bib_check(); }
}

/** Before the first run: the last .bbl this folder's BibTeX made, unless the folder's own .bbl is newer. */
static void bib_load_cache(void)
{
  if (!getenv("TAUDOT_BIB_CACHE")) return;
  char path[1100], own[1024];
  bib_cache_path(path, sizeof path, ".bbl");
  bib_aux_name(own, sizeof own, ".bbl");
  struct stat cs, os;
  if (stat(path, &cs) != 0 || cs.st_size == 0) return;
  if (stat(own, &os) == 0 && os.st_mtime > cs.st_mtime) return;
  fz_buffer *bbl = NULL, *sig = NULL;
  fz_try(ctx)
  {
    bbl = fz_read_file(ctx, path);
    bib_cache_path(path, sizeof path, ".bibsig");
    sig = fz_read_file(ctx, path);
    fz_terminate_buffer(ctx, sig);
  }
  fz_catch(ctx) {}
  if (bbl)
  {
    apply_open(own, (const char *)bbl->data, (int)bbl->len);
    if (sig) bib_sig = strdup((const char *)sig->data);
    if (tracing) fprintf(stderr, "[bib] cached .bbl, %d bytes\n", (int)bbl->len);
    fz_buffer *blg = NULL;
    bib_cache_path(path, sizeof path, ".blg");
    if (access(path, R_OK) == 0)
    {
      fz_try(ctx) blg = fz_read_file(ctx, path);
      fz_catch(ctx) blg = NULL;
    }
    bib_emit_log(blg);  // the warnings of the run that made it
    fz_drop_buffer(ctx, blg);
  }
  fz_drop_buffer(ctx, bbl);
  fz_drop_buffer(ctx, sig);
}

static void bib_quit(void)
{
  if (bib_pid) { kill(-bib_pid, SIGKILL); waitpid(bib_pid, NULL, 0); bib_pid = 0; }
  bib_cleanup();
}

// ---- main loop -----------------------------------------------------------------------------------------------------

static bool want_step(void)
{
  if (send(get_status, eng) != DOC_RUNNING) return false;
  if (send(is_finishing, eng)) return true;
  return true; // keep typesetting to the end; the goal only decides when to report early
}

/** After edits went in: TeXpresso has rolled back; typeset from there, and report again. */
static void changed(void)
{
  sync_pages();
  send(step, eng, ctx, true);
  if (lost_start()) recover_lost_start();
  sync_pages();
  goal_reported = false;
  done_reported = false;
  applied_at = now_us();
}

// ---- font stand-ins ---------------------------------------------------------------------------------------------
// times.sty, helvet, mathptmx, palatino, bookman, txfonts, charter, utopia, zi4, tgtermes... ask for families that
// pdfTeX (Overleaf) has as Type 1 fonts in 8-bit encodings (OT1, T1). XeTeX's default encoding is TU (Unicode), with no
// shapes for them, so LaTeX falls back to Latin Modern ("Font shape `TU/ptm/m/n' undefined"): other glyphs, other line
// breaks, other warnings. Each has an OpenType clone with the same metrics in Tectonic's bundle (TeX Gyre for the
// PostScript 35, XCharter, Erewhon for Utopia, Inconsolata-zi4). We give TeX a `tu<fam>.fd` for each, from memory
// (like the .bbl): never in the user's folder, and a file of that name in the folder wins. With [T1]{fontenc} the
// T1 .fd files already exist and pdfTeX's own Type 1 fonts are used. TAUDOT_NO_GYRE=1 turns this off.

/// Faces: upright and italic per weight; a NULL italic is the upright slanted (as XeTeX's slant=). "=fam": every shape
/// is a silent substitution (ssub) of that TU family's.
typedef struct { const char *fam, *r, *i, *b, *bi, *cr, *ci, *cb, *cbi, *scale; } gyre_family;

#define GYRE(stem) stem "-regular", stem "-italic", stem "-bold", stem "-bolditalic"
#define GYRE_CN GYRE("texgyreheroscn")
static const gyre_family gyre_families[] = {
  {"ptm", GYRE("texgyretermes")},                         // times, mathptmx, IEEEtran
  {"txr", GYRE("texgyretermes")},                         // txfonts' text: Times
  {"qtm", GYRE("texgyretermes")},                         // tgtermes
  {"phv", GYRE("texgyreheros"), GYRE_CN, "Hv@scale"},     // helvet
  {"qhv", GYRE("texgyreheros"), GYRE_CN},                 // tgheros
  {"pcr", GYRE("texgyrecursor")},                         // courier
  {"qcr", GYRE("texgyrecursor")},
  {"ppl", GYRE("texgyrepagella")},                        // palatino, mathpazo
  {"pxr", GYRE("texgyrepagella")},                        // pxfonts' text: Palatino
  {"qpl", GYRE("texgyrepagella")},
  {"pbk", GYRE("texgyrebonum")},                          // bookman
  {"qbk", GYRE("texgyrebonum")},
  {"pnc", GYRE("texgyreschola")},                         // newcent
  {"qcs", GYRE("texgyreschola")},
  {"pag", GYRE("texgyreadventor")},                       // avant
  {"qag", GYRE("texgyreadventor")},
  {"pzc", "texgyrechorus-mediumitalic"},                  // chancery: one face
  {"uzc", "texgyrechorus-mediumitalic"},
  {"qzc", "texgyrechorus-mediumitalic"},
  {"bch", "XCharter-Roman", "XCharter-Italic", "XCharter-Bold", "XCharter-BoldItalic"},  // charter
  {"put", "Erewhon-Regular", "Erewhon-Italic", "Erewhon-Bold", "Erewhon-BoldItalic"},   // utopia (fourier uses T1)
  {"zi4", "Inconsolatazi4-Regular", NULL, "Inconsolatazi4-Bold", NULL},                // inconsolata (acmart's tt)
  {"jkp", "KpRoman-Regular", "KpRoman-Italic", "KpRoman-Bold", "KpRoman-BoldItalic"},   // kpfonts (its OpenType)
  {"jkpss", "KpSans-Regular", "KpSans-Italic", "KpSans-Bold", "KpSans-BoldItalic"},
  {"jkptt", "KpMono-Regular", "KpMono-Italic", "KpMono-Bold", "KpMono-BoldItalic"},
  {"mdbch", "XCharter-Roman", "XCharter-Italic", "XCharter-Bold", "XCharter-BoldItalic"}, // mathdesign [charter]
  {"fvm", "DejaVuSansMono", "DejaVuSansMono-Oblique", "DejaVuSansMono-Bold", "DejaVuSansMono-BoldOblique", NULL, NULL,
   NULL, NULL, "fvm@Scale"},                              // beramono: Vera Sans Mono, DejaVu's Latin metrics
  {"txss", GYRE("texgyreheros")},                         // txfonts' and pxfonts' sans: Helvetica
  {"pxss", GYRE("texgyreheros")},
  {"txtt", "=lmtt"},  // their typewriter: 0.525 em like Latin Modern Mono, so a silent substitution keeps the breaks
  {"pxtt", "=lmtt"},
};

static const char *gyre_shapes[] = {"n", "it", "sl", "sc"};

static void gyre_shape(fz_buffer *b, const gyre_family *f, const char *w, const char *shape, const char *file,
                       bool slant)
{
  const char *feat = slant ? ";slant=0.167" : !strcmp(shape, "sc") ? ";+smcp" : "";
  fz_append_printf(ctx, b, "\\DeclareFontShape{TU}{%s}{%s}{%s}{<->%s\"[%s]:mapping=tex-text%s\"}{}\n", f->fam, w,
                   shape, f->scale ? "\\taudot@scale " : "", file, feat);
}

static void gyre_alias(fz_buffer *b, const char *fam, const char *w, const char *to)
{
  for (int i = 0; i < 4; i++)
    fz_append_printf(ctx, b, "\\DeclareFontShape{TU}{%s}{%s}{%s}{<->ssub * %s/%s/%s}{}\n", fam, w, gyre_shapes[i], fam,
                     to, gyre_shapes[i]);
}

/// One weight: n and sc (small caps) from `up`, it from `ital` (or `up` slanted), sl from `up` slanted.
static void gyre_weight(fz_buffer *b, const gyre_family *f, const char *w, const char *up, const char *ital)
{
  gyre_shape(b, f, w, "n", up, false);
  gyre_shape(b, f, w, "it", ital ? ital : up, !ital);
  gyre_shape(b, f, w, "sl", up, true);
  gyre_shape(b, f, w, "sc", up, false);
}

static fz_buffer *gyre_fd(const gyre_family *f)
{
  fz_buffer *b = fz_new_buffer(ctx, 2048);
  fz_append_printf(ctx, b, "\\ProvidesFile{tu%s.fd}[taudot: OpenType stand-ins for %s under XeTeX]\n", f->fam, f->fam);
  if (f->scale)
    fz_append_printf(ctx, b, "\\expandafter\\ifx\\csname %s\\endcsname\\relax\\def\\taudot@scale{}\\else"
                             "\\edef\\taudot@scale{s*[\\csname %s\\endcsname]}\\fi\n", f->scale, f->scale);
  fz_append_printf(ctx, b, "\\DeclareFontFamily{TU}{%s}{}\n", f->fam);
  if (f->r[0] == '=')
  {
    const char *ws[] = {"m", "b", "bx", "l", "sb", "db"};
    for (int w = 0; w < 6; w++)
      for (int i = 0; i < 4; i++)
        fz_append_printf(ctx, b, "\\DeclareFontShape{TU}{%s}{%s}{%s}{<->ssub * %s/%s/%s}{}\n", f->fam, ws[w],
                         gyre_shapes[i], f->r + 1, w ? "b" : "m", gyre_shapes[i]);
    return b;
  }
  if (!f->b)  // one face (Zapf Chancery): every shape and weight is it
  {
    gyre_shape(b, f, "m", "it", f->r, false);
    for (int i = 0; i < 4; i++)
      if (strcmp(gyre_shapes[i], "it")) fz_append_printf(ctx, b, "\\DeclareFontShape{TU}{%s}{m}{%s}{<->ssub * %s/m/it}{}\n", f->fam, gyre_shapes[i], f->fam);
    gyre_alias(b, f->fam, "b", "m");
    gyre_alias(b, f->fam, "bx", "m");
    return b;
  }
  gyre_weight(b, f, "m", f->r, f->i);
  gyre_weight(b, f, "b", f->b, f->bi);
  if (f->cr)
  {
    gyre_weight(b, f, "c", f->cr, f->ci);
    gyre_weight(b, f, "bc", f->cb, f->cbi);
  }
  gyre_alias(b, f->fam, "l", "m");   // Bookman's light
  gyre_alias(b, f->fam, "db", "b");  // Bookman's and Avant Garde's demibold
  gyre_alias(b, f->fam, "sb", "b");
  gyre_alias(b, f->fam, "bx", "b");
  return b;
}

static void gyre_install(void)
{
  const char *off = getenv("TAUDOT_NO_GYRE");
  if (off && *off && strcmp(off, "0")) return;
  for (size_t i = 0; i < sizeof gyre_families / sizeof *gyre_families; i++)
  {
    char name[32];
    struct stat st;
    snprintf(name, sizeof name, "tu%s.fd", gyre_families[i].fam);
    if (stat(name, &st) == 0) continue;  // the document's own (we are in its folder)
    fz_buffer *b = gyre_fd(&gyre_families[i]);
    apply_open(name, (const char *)b->data, (int)b->len);
    fz_drop_buffer(ctx, b);
  }
  if (tracing) fprintf(stderr, "[gyre] font stand-ins ready\n");
}

// rt/fonts.c: where to find glyphlist.txt and texglyphlist.txt (glyph names → text); TeX's file lookup
extern const char *(*rt_glyph_list_path)(const char *name);

int main(int argc, char **argv)
{
  rt_glyph_list_path = tectonic_get_file_path;
  bool use_tectonic = false;
  const char *doc_arg = NULL;
  for (int i = 1; i < argc; i++)
  {
    if (strcmp(argv[i], "-texlive") == 0) use_texlive = true;
    else if (strcmp(argv[i], "-tectonic") == 0) use_tectonic = true;
    else if (strcmp(argv[i], "-trace") == 0) tracing = true;
    else doc_arg = argv[i];
  }
  if (!doc_arg) { fprintf(stderr, "usage: txp-headless [-tectonic|-texlive] DIR/main.tex\n"); return 2; }
  if (!use_tectonic && !use_texlive) use_texlive = texlive_available() && !tectonic_available() ? true : false;
  if (use_tectonic && !tectonic_available()) { fprintf(stderr, "tectonic not in PATH\n"); return 1; }

  // our events keep the real stdout; TeXpresso's editor messages (printf to stdout) go to stderr
  int fd = dup(STDOUT_FILENO);
  fcntl(fd, F_SETFD, FD_CLOEXEC); // TeX processes and their snapshots must not hold our pipe open
  struct sigaction sa = {.sa_handler = on_signal}; // no SA_RESTART: poll returns EINTR
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);
  signal(SIGPIPE, SIG_IGN);
  out = fdopen(fd, "w");
  dup2(STDERR_FILENO, STDOUT_FILENO);
  // line by line: the app reads TeX's log from these as it is written (a pipe would be block buffered)
  setvbuf(stdout, NULL, _IOLBF, 0);

  static char doc_path[4096];
  if (!realpath(doc_arg, doc_path)) { perror(doc_arg); return 1; }
  char *slash = strrchr(doc_path, '/');
  *slash = 0;
  doc_name = slash + 1;
  doc_dir = doc_path;
  if (chdir(doc_path) != 0) { perror("chdir"); return 1; }

  // the engine binary sits next to the clone's texpresso
  const char *env = getenv("TEXPRESSO_XETEX");
  snprintf(engine_path, sizeof engine_path, "%s", env ? env : XETEX_PATH);

  ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
  fz_register_document_handlers(ctx);
  editor_set_protocol(EDITOR_JSON);
  editor_set_line_output(true);

  eng = txp_create_tex_engine(ctx, engine_path, use_texlive, false, "", doc_name, make_hooks());
  send(begin_changes, eng, ctx);  // no TeX process yet: only sets the .bbl's text
  bib_load_cache();
  gyre_install();
  send(end_changes, eng, ctx);
  send(step, eng, ctx, true);

  vstack *st = vstack_new(ctx);
  prot_parser parser;
  prot_initialize(&parser, 1);
  bool eof = false;
  first_edit_at = now_us(); // the first report measures the initial run

  while (!quitting)
  {
    bib_poll();
    bool busy = want_step();
    int timeout = busy ? 0 : bib_pid || bib_ready ? 50 : -1;  // a BibTeX job: look for its end every 50 ms
    bool aux_ready = !bib_pid && !bib_ready && !send(is_finishing, eng) && send(aux_dirty, eng);
    // ["rerun-once"] with nothing to rerun (idle, no BibTeX pending, the aux settled) is done: kept, it would fire
    // later in the middle of typing, past the idle wait (C15)
    if (rerun_once && !busy && !bib_pid && !bib_ready && !send(is_finishing, eng) && !aux_ready) rerun_once = false;
    if (!busy && aux_ready && (rerun_once || (rerun_enabled && rerun_count < MAX_RERUNS)))
    {
      int64_t idle = now_us() - last_edit_at;
      if (rerun_once || idle >= RERUN_IDLE_US)
      {
        if (tracing) fprintf(stderr, "[headless] rerun pass %d\n", rerun_count + 1);
        rerun_once = false;
        rerun_count++;
        send(start_finishing, eng);
        send(finish_convergence, eng, ctx); // finished already: restarts at once with the new aux, else at the end
        sync_pages();
        done_reported = false;
        timeout = 0;
      }
      else
        timeout = (int)((RERUN_IDLE_US - idle) / 1000) + 1;
    }
    // held edits go in once the page they were waiting for is out (or the run ended, or they waited too long)
    if (held_count && !holding())
    {
      send(begin_changes, eng, ctx);
      apply_held();
      if (bib_ready)  // a .bbl waiting for held edits goes in with them: typing never starves it (C11)
      {
        char name[1024];
        bib_aux_name(name, sizeof name, ".bbl");
        apply_open(name, (const char *)bib_ready->data, (int)bib_ready->len);
        fz_drop_buffer(ctx, bib_ready);
        bib_ready = NULL;
        rerun_count = 0;
      }
      if (send(end_changes, eng, ctx)) { changed(); timeout = 0; }
    }
    struct pollfd p = {.fd = STDIN_FILENO, .events = POLLIN};
    if (eof) break; // stdin closed: the preview is gone
    if (!eof && poll(&p, 1, timeout) > 0)
    {
      char buf[65536];
      ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
      if (n == 0) eof = true;
      else if (n > 0)
      {
        send(begin_changes, eng, ctx);
        const char *ptr = buf, *lim = buf + n;
        fz_try(ctx)
        {
          while ((ptr = prot_parse(ctx, &parser, st, ptr, lim)))
          {
            val cmds = vstack_get_values(ctx, st);
            int k = val_array_length(ctx, st, cmds);
            for (int i = 0; i < k; i++) interpret(st, val_array_get(ctx, st, cmds, i));
          }
        }
        fz_catch(ctx)
        {
          fprintf(stderr, "[headless] bad input: %s\n", fz_caught_message(ctx));
          vstack_reset(ctx, st);
          prot_reinitialize(&parser);
        }
        bool ch = send(end_changes, eng, ctx);
        if (tracing) fprintf(stderr, "[headless] read %zd bytes, changes: %d, held %d\n", n, ch, held_count);
        if (ch) { changed(); busy = true; }
        fflush(out);
      }
    }

    // step for at most ~5 ms, then look at stdin again
    int64_t t0 = now_us();
    while (want_step() && now_us() - t0 < 5000)
      if (!send(step, eng, ctx, false)) break;
    send(finish_convergence, eng, ctx);
    step_time += now_us() - t0;
    int after = send(page_count, eng);
    sync_pages();

    bool running = send(get_status, eng) == DOC_RUNNING;
    if (!goal_reported && goal >= 0 && after > goal && running)
    {
      report_pages(false);
      goal_reported = true;
    }
    if (!running && !done_reported)
    {
      report_pages(true);
      goal_reported = done_reported = true;
      bib_check();
    }
  }
  bib_quit();
  send(destroy, eng, ctx); // kills the TeX process and every snapshot
  return 0;
}
