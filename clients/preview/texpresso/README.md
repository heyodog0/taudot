# TeXpresso engine for the preview

**Reference only (2026-11-06).** The app no longer falls back to this `txp-headless` (it links MuPDF and isn't
shipped): it runs `clients/render/txp-render`, whose `driver.c` is a copy of this file with later fixes
(`docs/state-machines.md` C8–C11). Don't fix bugs here; read it for history.

`preview.ts --engine texpresso` typesets with [TeXpresso](https://github.com/let-def/texpresso) (MIT) instead of running
tectonic on every save. TeXpresso keeps the TeX process alive, snapshots it as it goes (by `fork`), and on an edit
rolls back to the last snapshot before the changed byte and typesets from there. Our preview keeps everything it
draws with: tiles, zoom, Kitty graphics, SyncTeX, quiet motion.

```sh
# once: build TeXpresso (needs: brew install mupdf pkgconf sdl2)
git clone https://github.com/let-def/texpresso ~/code/lab/taudot-ref/texpresso
cd ~/code/lab/taudot-ref/texpresso && make -j8 all
# the one-line patch that makes the snapshot interval a macro (optional; default 500 is kept without it):
#   src/frontend/engine_tex.c, need_snapshot(): `return time > TXP_SNAPSHOT_MS + last_time;`
clients/preview/texpresso/build.sh            # builds txp-headless (TEXPRESSO_DIR=... for another clone)

deno run -A clients/preview/preview.ts --folder DIR --engine texpresso [--taudot-socket ~/.taudot/engine.sock]
clients/rex/taudot-layout.sh --texpresso DIR  # the Rex layout with it
```

With `--taudot-socket` (or `$TAUDOT_SOCKET`) the preview subscribes to the engine's docs and hands each
`doc.changed` edit to TeXpresso as it arrives (both use UTF-8 byte offsets, so an edit maps one to one). Without it,
or for files the engine doesn't serve, a file save sends the whole file and TeXpresso diffs it.

## Files

| File | What |
|---|---|
| `txp-headless.c` | TeXpresso without its window: links its frontend objects except the SDL viewer. JSON lines on stdin (TeXpresso's editor commands, plus `goal`, `render`, `synctex`), JSON events out (`pages`). Header comment has the protocol |
| `client.ts` | The preview's side: spawn, edits, tile requests, `pages` events |
| `build.sh` | Builds `txp-headless` against a built clone |
| `bench-edit.ts` | Engine-side latency: edit on stdin → `pages` event → page rendered, plus tectonic's full compile |
| `trace-latency.sh`, `analyze-trace.ts` | Keystroke (engine `doc.edit`, mock engine) → frame written, from the preview's trace, in a background Rex session |
| `rex-latency.sh` | Keystroke → pixels in the Rex pane (brings a session to the front; `bench/latency.ts`) |
| `make-docs.ts` | The bench documents: 22-page plain text, a 12-page paper (figures, table, refs, natbib) |
| `snap-pages.ts` | PNGs of pages as TeXpresso draws them, to compare with tectonic's PDF |

## How the preview uses it

- `pages` events come early (as soon as the last page in view is typeset again, `goal`) and when the document is
  done. Only the pages listed in `changed` are rendered again; every other page keeps its images and tiles, which
  are re-tagged to the new generation. Until the end, pages past the ones typeset again keep their old size and
  content, so the document never shrinks mid-edit.
- A changed tiled page keeps its old sharp tiles on screen; the new tiles are requested together and placed in one
  frame (same Kitty image ids, so each transmission swaps in place). No blurry underlay in between.
- After 2 s without edits TeXpresso re-runs with the new `.aux` (up to 5 passes) so `\ref`, `\cite` and the table
  of contents settle in the background (`["rerun", false]` turns it off). Not sooner: a rerun starts TeX from scratch.
- While TeX works towards the goal page after edits, later edits are held and go in together once that page is
  reported (or the run ends, or after 1 s). Without that, keys 100–250 ms apart on page 1 kill every run before it
  ships the page (each rolls back into the font loading before page 1) and nothing shows until the typing stops.
- If an edit lands before a fresh run's first snapshot, TeXpresso kills that run's only process and stops for good
  ("No fences, assuming process finished": 0 pages, whatever is edited). txp-headless then makes the engine again
  with the open files and starts over (`lost_starts` in the `pages` event counts it).
- `pages` events carry `applied`, the open/change commands read so far: a client can tell which edits a report shows.

## Limits

- XeTeX only (TeXpresso's engine is Tectonic's XeTeX). pdfTeX-only code doesn't run.
- It never runs bibtex/biber: it reads the `.bbl` (and `.aux`, `.toc`) already in the folder.
- macOS: TeXpresso takes no snapshot before the first page is shipped (fonts must load before `fork`), so edits on
  the first page or two re-run from the preamble: ~70 ms on the long document instead of ~15.
- An edit to an `\input` file of a short document that has already finished may not be noticed (TeXpresso thinks the
  process saw none of that file); edits to the main file work.
- TeXpresso's own `change` command takes paths relative to the document only if they are absolute (it always calls
  `relative_path` on them); `txp-headless` takes paths as given.
- `txp-headless` keeps one TeX process plus up to 32 snapshot processes; they are killed when it exits or gets
  SIGTERM/SIGINT/SIGHUP (a SIGKILL leaves them: `pkill -f texpresso-xetex`).
