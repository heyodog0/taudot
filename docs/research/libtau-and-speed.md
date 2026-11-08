# libghostty, Typst's speed, incremental TeX, from-scratch TeX (research, 2026-11-07)

Sources read 2026-11-07; facts first with links, then inference.

## libghostty
- Two C APIs: **libghostty-vt** (public; `vt-1.0.0` tagged 2026-11-06; "The C ABI is stable from 1.0"; headers in
  `include/ghostty/vt/*.h`) and `include/ghostty.h` ("internal embedder API… only consumer is the macOS app… external
  embedders should use libghostty-vt").
- Internal API (~98 functions): opaque handles; host passes an NSView, core owns Metal rendering; host callbacks
  (`wakeup_cb`, `action_cb`, clipboard); host calls `ghostty_app_tick` on its thread after a wakeup.
- libghostty-vt: terminal state, render state ("a copy of everything you need to draw one frame"), two-phase update
  (begin under lock, end outside), dirty flags, stable row ids; **no GPU rendering**: the host draws.
- Stability: 1.x adds only; behaviour changes are new functions; CI ABI checks; snapshot byte format versioned
  separately. MIT. Embedders: JetBrains terminal, VS Code via WASM, Emacs, Flutter, others (awesome-libghostty).
- Links: https://github.com/ghostty-org/ghostty, https://mitchellh.com/writing/libghostty-is-coming

## Typst
- Incremental parser; memoized evaluation (pure functions, comemo with read-tracking constraints); layout cached per
  element; introspection iterates ≤5 times. Page-range partial compilation "simply not feasible" (#4512).
- Preview: tinymist sends binary vector-IR deltas to a WASM canvas renderer; only visible pages rendered.
- Third-party numbers: one paragraph edit 18 ms at 10 pages, 414 ms at 300 pages (rtex README, Typst 0.15.1);
  12.6 / 76 / 206 ms at 10 / 100 / 300 pages (Reddit, 0.14). Long watch sessions: memory growth, periodic full
  recompiles.
- Inference: TeX can't memoize like this (global mutable state, sequential expansion, output routines); its
  equivalent is prefix checkpointing (formats, fork snapshots), which Taudot already does.

## Incremental / fast TeX
- **TeXpresso** (MIT): patched XeTeX, fork snapshots + rollback, XDV → MuPDF. Exact for XeTeX.
- **rtex / realtime-tex** (MIT, v0.0.7, 2026-11-06; TUG 2026 paper by Clemens Lode): unmodified LuaLaTeX parked in
  `\begin{document}`; re-typesets only the edited paragraph/block with context captured by a background full pass;
  host paints the rows over the last layout; defers what it can't prove exact. **0.29–1.65 ms per edit, flat from 10
  to 300 pages.** Glyph display lists, PDF fallback for TikZ. C ABI / JSON lines; a VS Code extension.
- **BaKoMa TeX**: old "Dynamical Preview" re-typesetting the selected part; discontinued.
- **SwiftLaTeX** (AGPL): pdfTeX/XeTeX in WASM, full compiles only. **Tectonic**: XeTeX in Rust wrappers, not
  incremental. **web2js/TikZJax**: tex.web → WASM with a restorable memory dump (precedent for WASM snapshots).
  **LaTeX.js**: subset to HTML, not an engine.

## From scratch
- expl3 now needs e-TeX plus pdfTeX utilities incl. `\expanded` (pdfTeX ≥ 1.40.20, XeTeX ≥ 0.999991, LuaTeX ≥ 1.10).
- **RusTeX** (GPL): TeX/e-TeX/pdfTeX primitives, runs the real LaTeX kernel, outputs HTML, not paginated PDF.
  **Texcraft** (MIT): research subset, no PDF/DVI output. tex-rs, XymosTeX: inactive/learning.
- No reimplementation produces pdfLaTeX-identical PDFs for real papers. Exact needs ~340 primitives bug-for-bug,
  pdfTeX's backend and microtype's expansion/protrusion, TFM/VF/Type1, XeTeX's HarfBuzz path, LuaTeX's whole Lua
  node/callback API (effectively unbounded), patterns, engine-probing packages.

## Implications for Taudot (inference)
- **libtaudot-tex** like libghostty-vt: edits in, events out (pages, diagnostics, SyncTeX), a page render state
  (glyph runs, rules, images, vector fallback) with dirty flags and stable ids, two-phase updates, wakeup + pull.
  The Metal/PDFKit pane stays the app-internal layer. GPL engines stay separate processes; the library is an MIT
  client of `docs/live-protocol.md`. Snapshot/cache formats versioned outside the ABI.
- **From scratch: not realistic** for exact output. Instead, one shared harness per real engine: file-read log,
  snapshot/rollback, ship-out and line-break hooks, context capture.
- **Paths to Typst-class latency**, in order:
  1. Paragraph-level speculative typesetting from the snapshot before the edited paragraph (it already holds the
     exact context): fork, typeset only that paragraph, paint its lines over the page; exact pass replaces it.
     ~2–8 ms engine, ~25–35 ms key → pixels. Risks: wrapfig, lettrine, multicol, footnotes, `.aux` writers.
  2. Viewport-only finishing: page box tree → display list → Metal; write the PDF lazily. Exact path ~110 → ~50–70 ms.
     Needs own glyph rasterising and a PDF-literal interpreter (TikZ/pgf).
  3. Denser snapshots near the cursor and a pre-forked warm child: exact path toward ~20–40 ms. Cost: memory.
  4. WASM memory snapshots: for portability (web, iPad), not speed on macOS.
