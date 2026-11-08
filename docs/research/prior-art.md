# Prior art: what exists, where Taudot is new, where it is behind (2026-11-07)

Researched 2026-11-07 for going public. GitHub numbers (stars, last push, SPDX licence) are from `gh api` that day.
Every claim is marked **checked** (we read the code, file named, or ran it) or **read** (README, paper, site, post).
Overleaf-protocol clients that are AGPL were read, not copied. Nothing was logged into; no Overleaf project touched.

Taudot's own numbers come from our docs: `docs/universal.md` (agent/universal), the parapreview work's measurements (not
public), `docs/perf.md`. They are TeX Live 2026 on an M-series Mac with other agents' load.

## Summary

- **New, as far as we can find:**
  1. Exact live pdfTeX: a PDF byte-identical to stock after every key, with published latency (~50 ms edit → exact
     page, engine side; ~76–80 ms key → page shown in the app).
  2. libtau: line-granular fork snapshots and rollback on **unpatched** pdfTeX, XeTeX and LuaTeX via a libc
     interposer plus a few injected tokens, output byte-identical to stock. The *idea* was posted in 2022
     (Selinger) and never built; a one-checkpoint stock-TeX interposer appeared 2026-10-24 (liveTeX-Rosina).
  3. Paragraph preview on pdfTeX/XeTeX from the real engine state (a fork), pixel-identical to the final page.
     The paragraph preview itself is **not** new: rtex/texlode do it on LuaLaTeX, about as fast.
  4. PDF → source with each paragraph *proven* by re-typesetting (line breaks and glyph positions at sp level),
     with typesetting parameters and fonts recovered. Only planned (skeleton); proof-by-recompile exists for
     display math (pdfmath, 2026-09).
  5. `history-ot` writes on by default, one engine shared by app, CLI and agents.
- **Done elsewhere, ours not (yet) better:** review margin and Overleaf history (Lattice), a Claude Code pane
  (Lattice, Papilot, Octree), live SyncTeX PDF pane (Skim, Sioyek, everyone), PDF annotation (Acrobat, Zotero).
- **Behind:** Lattice ships most of the Overleaf-desktop story in one cross-platform app today (Apache-2.0, 314★,
  release today). rtex is open, MIT, and its preview is end-to-end ~0.3–1.7 ms; ours is ~13–17 ms key → pixels
  because it goes through the app's frame. Acrobat edits PDFs by chat (since ~2026-08).

## Matrix

● does it · ◐ partly / weaker · ○ planned · — no. Columns are Taudot's pieces:

| | Overleaf live sync | native Mac editor | exact live PDF | snapshots + rollback | ¶ preview | no engine patches | PDF → source | review margin | Claude / agent pane | live AI collaborator | PDF annotator / editor |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **Taudot** | ● ST + HO | ● Neovim/Metal | ● pdfTeX | ● | ● pdfTeX, XeTeX, Lua | ● (libtau) | ○ skeleton | ● | ● | ○ | ○ |
| Overleaf | (is the server) | — web | ● (is the reference) | — | — | n/a | — | ● | ◐ AI assistant | — | — |
| Lattice | ● ST only | ◐ Tauri | — compile | — | — | n/a | — | ● | ● | ◐ diff review | — |
| overleaf-mcp-rt | ● ST + HO (opt-in) | — | — | — | — | n/a | — | ◐ comments API | — | ◐ protocol only | — |
| Overleaf Workshop | ◐ diff on save | — VS Code | — | — | — | n/a | — | — (PR open) | — | — | — |
| olcli | ◐ REST per file | — CLI | — | — | — | n/a | — | ◐ CLI | — | — | — |
| TeXpresso | — | — | ◐ XDV, no PDF | ● patched XeTeX | — | — | — | — | — | — | — |
| rtex (realtime-tex) | — | — VS Code | ◐ final PDF only | — (context capture) | ● LuaLaTeX | ● | — | — | — | — | — |
| texlode (Lode) | — | — browser | ◐ | — | ● LuaLaTeX | ● | — | — | — | — | — |
| liveTeX-Rosina | — | — | — provisional | ◐ one checkpoint | ◐ 27–88 ms | ● | — | — | — | — | — |
| Texifier / Texpad | — | ● | ◐ own TeX fork | ? | ● live typeset | — | — | — | — | — | — |
| BaKoMa TeX | — | — Windows | ? own TeX | ? | ● (dead) | — | — | — | — | — | — |
| SwiftLaTeX | — | — web | ● full compiles | — | — | ● WASM | ◐ own docs only | — | — | — | ◐ edit in PDF view |
| Typst + tinymist | — | — | n/a | (memoised) | ◐ incremental | n/a | — | ◐ comments | — | — | — |
| TeXlyre | — (Yjs) | — web | ● busytex | — | — | ● | — | ● | — | — | — |
| Prism (closing 2027-01-01) | — | — web | ● | — | — | — | — | ◐ comments | ● | ◐ approve | — |
| Papilot / Octree | — | — | — | — | — | — | — | — | ● | ◐ approve | ◐ mark on PDF |
| TeXShop, TeXstudio, LaTeX Workshop, VimTeX | — | ◐ (TeXShop) | ● compile | — | — | n/a | — | — | — | — | — |
| Skim, Sioyek, zathura | — | ● (Skim) | n/a | — | — | n/a | — | — | — | — | ◐ notes |
| Zotero + zotero-mcp | — | — | — | — | — | — | — | — | ● | ◐ highlights | ● annotator |
| Acrobat | — | ● | — | — | — | — | — | — | ● | ◐ chat edits | ● (glyph moving) |
| Stirling-PDF, PDF4QT, KillerPDF | — | — | — | — | — | — | — | — | — | — | ◐ glyph moving |
| pdfmath | — | — | — | — | — | — | ◐ math, proven | — | — | — | — |
| go-pdfkit/latex | — | — | — | — | — | — | ◐ whole doc, unproven | — | — | — | — |
| Nougat, MinerU, Mathpix, TexOCR | — | — | — | — | — | — | ◐ OCR, unproven | — | — | — | — |

## 1. Local editing of Overleaf projects with live sync

| Project | What | Licence, ★, last push | Evidence |
|---|---|---|---|
| [leo1oel/lattice](https://github.com/leo1oel/lattice) | Mac app (Tauri + CodeMirror), own Rust socket client, ShareJS OT with a randomised convergence test, presence, chat, comments, suggestions (`meta.tc`), accept, history + latexdiff, SyncTeX, Claude Code/Codex panel. `joinDoc` without `supportsHistoryOT`: migrated projects refused | Apache-2.0, 314, 2026-11-07 (v0.15.8) | **checked** `src-tauri/src/overleaf_rt.rs`, `overleaf_rt/{client,codec}.rs`, `src/overleaf/ot.ts` |
| [DanielHou315/overleaf-mcp-rt](https://github.com/DanielHou315/overleaf-mcp-rt) | MCP server: live doc snapshot, inflight transform, confirm on `otUpdateApplied`, history-ot read + opt-in write with its own TextOperation transform; live test matrix on CE 4.2/5.5/6.0/6.3; comments add/reply/resolve | AGPL-3.0-or-later (port of Workshop), 13, 2026-09-20 | **checked** `src/overleaf/{ot,text-ot,history-ot,socket}.ts`, `CLAUDE.md` |
| [GhoshSrinjoy/Overleaf-mcp](https://github.com/GhoshSrinjoy/Overleaf-mcp) | MCP + VS Code; ST + HO one-shot ops; "suggest mode" tracked changes | MIT, 10, 2026-10-15 | **checked** `src/core/overleaf/ot.ts`, `realtime.ts` |
| [aloth/olcli](https://github.com/aloth/olcli) | CLI, reads ST + HO over the socket, writes whole files over REST; comments, tracked changes accept/reject | MIT, 248, 2026-11-07 | **checked** `src/client.ts` |
| [overleaf-workshop/Overleaf-Workshop](https://github.com/overleaf-workshop/Overleaf-Workshop) | VS Code; diff on save, no transforms; review panel PR #95 open since 2024-02 | AGPL-3.0, 1,703, 2026-10-03 | **checked** (README, `src/`, open PRs) |
| [ayghri/overleaf-mcp](https://github.com/ayghri/overleaf-mcp) | Python MCP, live ST, every agent edit a tracked change | MIT, 5, 2026-10-19 | **checked** `overleaf_mcp/editor.py` |
| [mei28/nvim-overleaf](https://github.com/mei28/nvim-overleaf), [da-h/airlatex.vim](https://github.com/da-h/airlatex.vim) | Neovim / Vim plugins, ST only, bugs in `docs/prior-art.md` | MIT; 2 (2026-04-06), 88 (2023-05-29) | **checked** |
| [moritzgloeckl/overleaf-sync](https://github.com/moritzgloeckl/overleaf-sync), [mjyoo2/OverleafMCP](https://github.com/mjyoo2/OverleafMCP), ~10 more | zip/REST/git bridge, not real time | MIT; 396, 345 | **checked** `olsync/olclient.py` |
| [Overleaf](https://www.overleaf.com/user/subscription/plans) | Git/Dropbox/track changes/full history only on $98–399/yr; CE at 6.3.2 | AGPL (CE) | **read** plans; **checked** `overleaf/toolkit` `lib/config-seed/version` |

Verdict: **partly new.** Live OT sync of Overleaf from a desktop app shipped in Lattice on 2026-07-24, and
history-ot is spoken by three clients. What nobody ships: history-ot **writes by default**, and one background
engine that the app, a CLI with `--json` and agents share (everyone else ties sync to one host process). That edge is
real only with convergence tests as strong as mcp-rt's per-version CE matrix.

## 2. Native macOS editor (Neovim and Metal native modes)

- Native Mac LaTeX editors: TeXShop (GPL, Cocoa), [Texifier](https://www.texifier.com) (closed, ~€50). No Overleaf, no
  Neovim. **read**
- Metal-drawn Neovim GUIs, none inside a LaTeX app: [akiyosi/zonvie](https://github.com/akiyosi/zonvie) (MIT, 161,
  2026-11-06), [0x1b2c/Veil](https://github.com/0x1b2c/Veil) (MIT, 41), [sfsam/Nvmm](https://github.com/sfsam/Nvmm)
  (MIT, 20), [JaySandhu/neovim-mac](https://github.com/JaySandhu/neovim-mac) (MIT, 179, inactive since 2024-03);
  [qvacua/vimr](https://github.com/qvacua/vimr) (MIT, 7,014, 2026-10-10) ships `NvimView`, an embeddable NSView;
  [neovide](https://github.com/neovide/neovide) (MIT, 15,296, Skia). **read**
- Neovim into Overleaf's web editor: Firenvim (GPL, 6,164; open issue "Overleaf broke firenvim", 2025-03), GhostText.
  **read**
- Web-tech desktop shells: Lattice, Corollary, Papilot, Texpile.

Verdict: **new as a combination**, not in its parts. Our measured key → glyph (Neovim/Metal p50 14.7 ms, p99 26 ms,
`docs/perf.md`) is the claim to publish; no LaTeX app publishes one.

## 3. Live PDF byte-identical to stock pdfLaTeX / Overleaf

| Project | Engine and output | Numbers | Licence, ★, push | Evidence |
|---|---|---|---|---|
| **Taudot** (patched pdfTeX, `clients/pdftex`) | stock-identical PDF per key | edit → exact page p50 ~46–50 ms (32–48 pp.); in app key → page shown p50 76–80 ms | AGPL (app) / GPL (engine patches) | ours |
| [let-def/texpresso](https://github.com/let-def/texpresso) | patched XeTeX, XDV drawn by own DVI interpreter + MuPDF; **no PDF** | none published | MIT, 806, commit 2026-07-22 | **checked** `src/engine/main/fork.c`, `src/frontend/engine_tex.c` |
| [HenryXiaoYang/realtime-tex](https://github.com/HenryXiaoYang/realtime-tex) | LuaLaTeX; final PDF = clean stock build; pages exact only after a background pass (0.2 s at 10 pp, ~5–10 s at 300 pp) | see §5 | MIT, 276, 2026-11-06 | **checked** `docs/how-it-works.md`, `tex/rtex-serve.lua` |
| [Texifier "Live Typeset"](https://www.texifier.com/docs/apps/typesetting/typesetters/texpadtex) | own rewritten TeX fork (TexpadTeX, 2017), falls back to MacTeX | none; no identity claim | closed | **read** |
| [SwiftLaTeX](https://github.com/SwiftLaTeX/SwiftLaTeX), [busytex](https://github.com/busytex/busytex), [Tectonic](https://github.com/tectonic-typesetting/tectonic) | stock engines (WASM / Rust wrapper), **full** compiles | — | AGPL 2,320 (2024-06); 79 (2026-11-01); MIT 5,232 (2026-07-31) | **read** |
| Overleaf | full server compile; "fast/draft" mode | texlode claims "up to 62 s for large documents" (vendor) | — | **read** |
| [Typst](https://github.com/typst/typst) | not LaTeX; memoised incremental | watch: 18 / 146 / 414 ms at 10 / 100 / 300 pp (rtex's bench, Typst 0.15.1) | Apache-2.0, 57,036 | **read** |

Verdict: **done before (architecture), ours better (result).** Fork snapshots + rollback + files from memory is
TeXpresso's design (2023), first described by Selinger in 2022. Nobody else delivers a stock-identical whole page or
PDF per keystroke, and nobody else publishes a latency for it. TeXpresso forks every ~500 ms of engine time
(`need_snapshot`, engine_tex.c ~l.474); we snapshot at line reads near the cursor.

## 4. Engine-agnostic live typesetting without patches (libtau)

- **Peter Selinger, pdftex list, 2022-01-15** ([thread](https://tug.org/pipermail/pdftex/2022-January/thread.html)):
  "can almost be done at the operating system level … except to replace a few system calls": snapshot the process,
  track reads, restart from the newest unaffected snapshot. Ross Moore and Doug McKenna doubted it. No
  implementation found. **read**
- [PetalAdrift/liveTeX-Rosina](https://github.com/PetalAdrift/liveTeX-Rosina) (custom restrictive licence, 7★,
  created 2026-10-24): `fopen`/`fclose` interposer via `DYLD_INSERT_LIBRARIES`/`LD_PRELOAD` on stock pdfTeX and
  XeTeX; **one** fork point after the preamble, no rollback inside the body; provisional fragment PDFs composited on
  old pages; pdfLaTeX 27–43 ms, XeLaTeX 78–88 ms (README). **checked** `src/resident_hook.cpp`
- rtex and texlode run stock LuaLaTeX with no patches, by a different route (a Lua serve loop plus captured context).
- TeXpresso intercepts I/O inside a patched engine.

Verdict: **partly new.** Interposing on stock TeX is no longer a novel claim (Selinger's idea, Rosina's build).
Not found anywhere: line-granular snapshots with rollback on all three unpatched engines, byte-identical output,
the `\pdffilesize`/`\filesize` ship hook, finishing early by injecting `\end`, and zcache over an interposed zlib.

## 5. Sub-frame paragraph preview

| Project | Route | Speed | Exactness | Engines |
|---|---|---|---|---|
| **Taudot** | fork the snapshot at the paragraph, typeset it alone, paint over the page | TeX time p50 1.28 (pdfTeX) / 1.43 (XeTeX) ms on PaperA; patched pdfTeX key → paragraph pixels ~13–17 ms p50 | pixel-identical to the final page (16/17, 11/11 on 300 pp.; libtau overlays 27/28) | pdfTeX, XeTeX, LuaTeX |
| [rtex](https://github.com/HenryXiaoYang/realtime-tex) | parked LuaLaTeX restores context captured by a background run; allow-list + probe + leak checks | `apply_edit` → decoded paragraph 0.29–1.65 ms, flat 10–300 pp (cloud VM) | glyph-identical to 1 sp, CI-checked; pagination may be stale | LuaLaTeX |
| [texlode](https://texlode.com) / [Lode, TUG 2026](https://www.tug.org/tug2026/preprints/lode-realtime.pdf) | same idea, closed, browser | line breaking 0.17–1.99 ms; round trip 0.79–6.11 ms | — | LuaLaTeX |
| liveTeX-Rosina | fork after preamble, fragment PDF | 27–88 ms | provisional | pdfTeX, XeTeX, (LuaTeX worker) |
| BaKoMa Dynamical Preview (~2002), Fine's Instant Preview ([TUGboat 22(4) 2001](https://tug.org/TUGboat/tb22-4/tb72fine.pdf)), WhizzyTeX | re-typeset the edited part | — | own engines / slices | dead or dormant |

All rtex claims **checked** in its code/docs; numbers **read**. Lode's benchmark repo admits the paper's Typst
numbers do not reproduce with its script (issue #1). [HN, 2026-07-18](https://news.ycombinator.com/item?id=48962944).

Verdict: **done elsewhere for LuaLaTeX at the same or better speed.** Ours differs in engines (pdfTeX and XeTeX,
which is what Overleaf users compile with) and in getting the state from a fork instead of a capture vocabulary, so
macros, catcodes and `\parshape` from anywhere earlier just work. We quote TeX time and rtex quotes end to end:
publish key → pixels so the two compare.

## 6. PDF → source, proven by re-typesetting

| Project | Method | Numbers | Proof? | Licence, ★, push |
|---|---|---|---|---|
| [adamdeprince/pdfmath](https://github.com/adamdeprince/pdfmath) | glyphs as (font, code), inverts TeX's Appendix G, `pdfmath roundtrip` recompiles with pdfTeX and compares glyph positions at 0.02 pt | real arXiv: 87.3% of displays structurally right, **3.9%** glyph-identical (28.3% with regions from source) | yes, per equation; **display math only** | MIT, 0, 2026-09-20 |
| [go-pdfkit/latex](https://github.com/go-pdfkit/latex) | pure Go, geometry → lines → paragraphs, styles from font names, math, repair pass | 275 arXiv papers: 99.6% compile, word F1 0.67, round-trip ink F1 0.32–0.40 | measured, not proven; no TeX parameters | BSD-3, 1, 2026-11-06 |
| MaxTract (Birmingham, 2010–12, [thesis](https://etheses.bham.ac.uk/id/eprint/3377/)) | formulas from PDF glyph data | — | no | code gone |
| [TexOCR](https://github.com/QDRhhhh/TexOCR) (ACL 2026, arXiv:2604.22880) | 2B VLM, compile success as RL reward | 45.2% compile (GPT-5.3: 82.7%) | no page comparison | none, 17 |
| Nougat, MinerU, Marker, olmOCR, docling, Mathpix, … | page image → Markdown/LaTeX | Nougat BLEU 89.1; olmOCR-Bench 75–83 | no | MIT…AGPL; 10k–92k★ |
| im2markup (2017), CDM, Image2Struct; LATTE, DeTikZify | render-and-compare as a **metric** or as neural **feedback** | — | no | — |
| [LaTeX Tagging Project](https://github.com/latex3/tagging-project) | tagged PDF 2.0; `tex-AF` attaches each formula's source | — | free ground truth when present | LPPL |

pdfmath and go-pdfkit **checked** (`pdfmath/eval/roundtrip.py`, `docs/evaluation.md`; `line.go`, `block.go`,
`rule.go`); numbers **read**. We ran pdfminer and PyMuPDF via `uvx` on a PDF of our own: PyMuPDF's `rawdict` exposes
`\baselineskip` (11.955 bp = 12 pt) and microtype protrusion (0.1–0.4 bp at line edges). **checked**. Nothing found
that inverts Knuth–Plass, infers `\tolerance`/`\hsize`/microtype from output, or identifies fonts by comparing
subset outlines (both close tools use font names).

Verdict: **partly new.** Proof by recompile exists for display math (pdfmath); cite it. New: paragraph-level proof
(every break and glyph at sp), parameter recovery, outline font identification, and the same proof for non-TeX
producers. pdfmath's 87% vs 4–28% gap warns that "structure right" and "sp-identical" are far apart; "proven" should
mean "a source that typesets to this page", not "the author's source". Producers vary: tectonic writes via
xdvipdfmx, and many arXiv PDFs went through dvips + Ghostscript.

## 7. Review margin (threads, history, diffs)

Lattice has margin cards for Overleaf comments and suggestions, accept, chat, presence, and a history timeline with
latexdiff (**checked**, file list and protocol doc). Overleaf, [TeXlyre](https://github.com/texlyre/texlyre)
(AGPL, 1,008★, Yjs, comments **and** tracked changes) and Typst (comments, Pro) have review panels; olcli and
overleaf-mcp-rt do comments from the CLI/agent side. Overleaf Workshop's review PR has been open since 2024.

Verdict: **done elsewhere (Lattice).** Ours is better only on migrated (history-ot) projects, which Lattice can't
open, and on being native and faster: both need numbers.

## 8. Claude in the app

Lattice's agent panel runs Claude Code, Codex and others with a terminal; [Papilot](https://github.com/PapilotAI/papilot)
(MIT, 163★, 2026-10-26) lets you mark text on the PDF and your agent edits the source in a git worktree;
[Octree](https://github.com/octree-labs/octree) (LGPL, 300★) has Claude chat; Overleaf's AI assistant is a chat
panel on paid plans (beta 2025-12-10). [OpenAI Prism](https://openai.com/index/introducing-prism) (Crixet,
2026-01) is reported to shut on 2027-01-01 (HN post 2026-10-30 and a secondary summary; OpenAI's help page returned
403 to us, so unverified). **read**

Verdict: **done elsewhere; table stakes.**

## 9. Planned: an AI agent editing, commenting and highlighting live in the document

- Protocol half exists, no UI: overleaf-mcp-rt (live OT edits under your account, comments, tells the agent about
  concurrent human edits), ayghri (live tracked changes), GhoshSrinjoy (suggest mode). **checked**
- UI half exists, as suggest-then-approve: Google Docs Gemini (2026-07), Word Copilot with tracked changes (2026),
  Notion suggested edits (2026-08), Lattice, Papilot, Acrobat "edit PDFs via chat"
  (~2026-08: rewrite by meaning, add/remove highlights, accept or skip each change). **read**
- Reader-side highlighting: [54yyyu/zotero-mcp](https://github.com/54yyyu/zotero-mcp) (MIT, 5,796★): an agent places
  highlights on exact words, locating text by anchor → exact → fuzzy (±2 pages) with "did you mean";
  [llm-for-zotero](https://github.com/yilewang/llm-for-zotero) (AGPL, 3,520★, `annotate_pdf`); SkimRead (temporary
  highlights until saved); Semantic Reader; alphaXiv. **checked** (`docs/ANNOTATION_FEATURE.md`,
  `src/agent/tools/write/annotatePdf.ts`)

Verdict: **partly.** Nobody shows an agent as a visible collaborator (cursor, live highlights, margin cards) in a
native editor on a shared Overleaf doc, with comments anchored to the source so they survive recompiles. Everyone
defaults agent edits to suggestions; do the same (`meta.tc` tracked changes), since agent edits under the user's
name with no marker will worry co-authors.

## 10. Planned: PDF annotator / editor

- Viewers with SyncTeX: [Skim](https://skim-app.sourceforge.io) (BSD, PDFKit), [Sioyek](https://github.com/ahrm/sioyek)
  (GPL, 9,988★; Portals, Smart Jump; MuPDF), zathura, SumatraPDF, Okular, PDF.js (annotations, no text editing).
  **checked** Sioyek `pdf_viewer/synctex/synctex_parser.c`, PDF.js `src/display/editor/`
- Annotators: Zotero 8/9 (AGPL; annotations as searchable items), Highlights, PDF Expert, PDFgear, Foxit, MarginNote.
  **read**
- Text editors, all glyph moving with greedy wrap in the old box; for glyphs missing from a subset:
  Acrobat needs the font installed (**read**, Adobe help); Master PDF and PDF Studio refuse and ask (**read**);
  [PDF4QT](https://github.com/JakubMelka/PDF4QT) errors "Cannot encode character with cid" (MIT, 1,508★; **checked**
  `pdfpagecontenteditorcontentstreambuilder.cpp`); [Stirling-PDF](https://github.com/Stirling-Tools/Stirling-PDF)
  2.x substitutes width-compatible Liberation/Noto, and its own test documents untouched lines re-wrapping (95,968★;
  **checked** `pdfiumFontFallback.ts`, `pdf-text-editor-reflow-justified.spec.ts`);
  [KillerPDF](https://github.com/SteveTheKiller/KillerPDF) whites out the line and types over in Segoe UI (GPL, 4,338★; **checked**
  `PdfViewer.TextEditing.cs`). None keeps TeX line breaking.
- SwiftLaTeX's research version (~2018–19) edited in the PDF view and mapped edits back to source via a patched
  engine, for documents it compiled itself. **read**

Verdict: annotation **done better elsewhere**; editing a PDF by recovering its proven source: **new** (SwiftLaTeX
did own documents only). Live pane with SyncTeX: **done**; ours better only measured (no MuPDF, no flash,
scroll kept).

## Where Taudot should push hardest

1. **Exact and live on the engines people actually use.** Byte-identical-to-Overleaf pdfLaTeX per keystroke, and a
   paragraph preview on pdfTeX/XeTeX, are things nobody else has. Publish the numbers end to end (key → pixels,
   key → exact page) beside rtex's and Typst's, on the same 10/100/300-page documents, with a reproducible script.
2. **libtau as the product under the product.** Stock engines, no patches, all three engines, byte-identical. A
   library other editors embed (VS Code, Zed, Neovim, Emacs, web via WASM later) is how this becomes the standard
   rather than one app's feature, and it is where Rosina and rtex are each only partway.
3. **history-ot and a shared engine.** Overleaf is migrating projects; Lattice and Workshop will break on them.
   Ship history-ot writes on by default, with a CE convergence matrix per version, and say so.
4. **Proven PDF → source.** Nobody proves paragraphs. Start where proof is cheapest (pdfTeX-produced arXiv PDFs,
   prose paragraphs), report the proven rate honestly, and make "edit any LaTeX PDF in place, line breaks intact"
   the demo. It beats every PDF editor's glyph moving.
5. **The agent as a visible co-author.** Cursor, highlights and margin cards in the native editor, tracked changes
   by default, anchored to source. The protocol half exists in MCP servers; the experience doesn't.
6. **Timing.** Prism closes 2027-01-01 (unverified); its users are choosing a new home in Nov–Dec 2026.

## Borrow instead of build

- **SyncTeX parsing:** TeX Live's `synctex_parser.c` (as Sioyek and zathura do).
- **Reading features for the pane:** Sioyek's Smart Jump/Overview and Portals (ideas; its code is GPL).
- **Annotations:** write standard PDF annotation objects so Preview, Skim and Zotero read them; Zotero's model
  (annotations as searchable items, export to notes).
- **Agent text location and review flow:** zotero-mcp's anchor → exact → fuzzy locator (MIT); Acrobat's
  confirm-the-plan and accept/skip per change; SkimRead's temporary highlights; an MCP surface for outside agents.
- **Protocol cross-check:** overleaf-mcp-rt's `CLAUDE.md` facts (ack ≠ applied; history-ot versions not restamped;
  ST/HO transforms disagree on some overlaps; surrogates → U+FFFD) against `docs/protocol.md`. Read only: AGPL.
- **Embedding Neovim:** VimR's `NvimView` (MIT) as a reference for the msgpack-RPC side.
- **Missing glyphs in edited PDFs:** real font from TeX Live first; Stirling's width-compatible fallback table
  (MIT core) second.
- **PDF → source proposals:** OCR models (Nougat, TexOCR) only as a proposal step; tagged PDFs' structure tree and
  `tex-AF` formula source as free ground truth; pdfmath's evaluation as the baseline for the math stage.
- **Low-level PDF edits:** PDF4QT (MIT) as a reference for content streams and font resources.
- **Don't build:** a general annotator to rival Acrobat/Zotero, a cross-platform review UI to rival Lattice, a
  chat pane beyond the Claude Code one.

## Not settled

- Prism's shutdown date (OpenAI's page not read directly). Skim's exact licence. Zotero 10. Prices for LiquidText,
  Papers, PDF Expert.
- Texifier's live typesetter: no numbers or exactness claims to compare against; worth a hands-on run.
- TeXpresso's cited TUGboat 44(2) article: URL 404, not found.
- No published tinymist preview latency.
- We read code but ran none of the competitors (no builds of cloned code). A side-by-side run of rtex, TeXpresso and
  Rosina against ours on the same papers is the obvious next measurement.
