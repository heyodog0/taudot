// txp-headless: TeXpresso's incremental LaTeX engine without its window, for the taudot preview.
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
// stdout: JSON objects, one per line (TeXpresso's own editor messages are JSON arrays and go to stderr):
//   {"id":ID,"ok":true,"w":W,"h":H,"cpu_us":N}                   render done
//   {"ev":"pages","gen":G,"applied":A,"n":N,"done":B,"sizes":[[w,h],...],"changed":[i,...],"edit_us":E,"step_us":S}
//      at quiet points: when the goal is reached and again when the document is finished. `changed` lists pages
//      whose content differs from the last "pages" event (by a hash of the page's drawing). `edit_us` is the time
//      since the first edit applied after the previous event, `step_us` the engine time spent since then. `applied`
//      counts the open and change commands read so far: the report shows all of them.
//   {"ev":"error","line":"..."}                                  a "! ..." line from TeX's output

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

#include <mupdf/fitz.h>

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

// FNV-1a over a trace of the page's drawing: same glyphs, paths and positions → same hash.
static uint64_t hash_page(int page)
{
  fz_display_list *dl = page_dl(page);
  if (!dl) return 0;
  fz_buffer *buf = fz_new_buffer(ctx, 65536);
  fz_output *o = fz_new_output_with_buffer(ctx, buf);
  fz_device *dev = fz_new_trace_device(ctx, o);
  fz_run_display_list(ctx, dl, dev, fz_identity, fz_infinite_rect, NULL);
  fz_close_device(ctx, dev);
  fz_drop_device(ctx, dev);
  fz_close_output(ctx, o);
  fz_drop_output(ctx, o);
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0; i < buf->len; i++) { h ^= buf->data[i]; h *= 1099511628211ULL; }
  fz_drop_buffer(ctx, buf);
  return h;
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
    // early report, on the latency path: every page typeset again counts as changed, no hashing (~8 ms a page).
    // Usually one or two pages: from the snapshot TeXpresso rolled back to, to the page in view.
    for (int i = retyped_from; i < n; i++) fprintf(out, "%s%d", k++ ? "," : "", i);
    if (retyped_from < unhashed_from) unhashed_from = retyped_from;
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
  fz_irect box = fz_make_irect(x, y, x + w, y + h);
  fz_pixmap *pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), box, NULL, 0);
  fz_clear_pixmap_with_value(ctx, pix, 255);
  fz_rect b = fz_bound_display_list(ctx, dl);
  fz_matrix m = fz_concat(fz_translate(-b.x0, -b.y0), fz_scale(scale, scale));
  fz_device *dev = fz_new_draw_device(ctx, fz_identity, pix);
  fz_run_display_list(ctx, dl, dev, m, fz_rect_from_irect(box), NULL);
  fz_close_device(ctx, dev);
  fz_drop_device(ctx, dev);
  // samples are w*3 per row with stride; write packed rows
  unsigned char *samples = fz_pixmap_samples(ctx, pix);
  int stride = fz_pixmap_stride(ctx, pix);
  size_t size = (size_t)w * h * 3;
  unsigned char *packed = samples;
  if (stride != w * 3)
  {
    packed = malloc(size);
    for (int r = 0; r < h; r++) memcpy(packed + (size_t)r * w * 3, samples + (size_t)r * stride, w * 3);
  }
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
  if (packed != samples) free(packed);
  fz_drop_pixmap(ctx, pix);
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
static held_edit held[4096];
static int held_count;
static int64_t applied_at;  // when the edits now being typeset were applied (0: none pending)

static bool holding(void)
{
  return applied_at && !goal_reported && goal >= 0 && send(get_status, eng) == DOC_RUNNING
    && now_us() - applied_at < HOLD_MAX_US;
}

static void hold(int tag, const char *path, int offset, int remove, const char *data, int length)
{
  if (held_count == (int)(sizeof held / sizeof *held)) return;  // can't happen at typing speed; dropped edits would desync
  held_edit *h = &held[held_count++];
  h->tag = tag;
  h->path = strdup(path);
  h->offset = offset;
  h->remove = remove;
  h->length = length;
  h->data = data ? memcpy(malloc(length + 1), data, length) : NULL;
}

static void apply_held(void)
{
  for (int i = 0; i < held_count; i++)
  {
    held_edit *h = &held[i];
    if (h->tag == EDIT_OPEN) { edits_applied++; apply_open(h->path, h->data, h->length); }
    else if (h->tag == EDIT_CHANGE) { edits_applied++; apply_change(h->path, h->offset, h->remove, h->data, h->length); }
    else if (h->tag == EDIT_CLOSE) apply_close(h->path);
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
    case EDIT_RESCAN:
      send(detect_changes, eng, ctx);
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

int main(int argc, char **argv)
{
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
  send(step, eng, ctx, true);

  vstack *st = vstack_new(ctx);
  prot_parser parser;
  prot_initialize(&parser, 1);
  bool eof = false;
  first_edit_at = now_us(); // the first report measures the initial run

  while (!quitting)
  {
    bool busy = want_step();
    int timeout = busy ? 0 : -1;
    bool aux_ready = !send(is_finishing, eng) && send(aux_dirty, eng);
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
    }
  }
  send(destroy, eng, ctx); // kills the TeX process and every snapshot
  return 0;
}
