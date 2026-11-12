# txp-headless

[TeXpresso](https://github.com/let-def/texpresso) (MIT) without its window: JSON lines on stdin (TeXpresso's editor
commands plus `goal`, `render`, `synctex`), JSON events out (`pages`); the protocol is in `txp-headless.c`'s header.
The app runs `clients/render/txp-render`, whose `driver.c` started as a copy of this file. `txp-headless` links
MuPDF (AGPL) and is never shipped. `install.sh` and `bench/build.sh` still build it, and the Rex layout's
`--texpresso` runs it.

```sh
sh clients/render/texpresso/apply.sh DIR && make -C DIR -j8 all   # a patched TeXpresso
TEXPRESSO_DIR=DIR clients/preview/texpresso/build.sh              # txp-headless (TXP_SNAPSHOT_MS, default 500)
```

The rest are benches: `bench-edit.ts` (edit → `pages` → page rendered), `trace-latency.sh` / `analyze-trace.ts` and
`rex-latency.sh` (keystroke to pixels), `make-docs.ts` (bench documents), `snap-pages.ts` (page PNGs to compare with
Tectonic's PDF). `client.ts` is the Deno preview's side (`preview.ts --engine texpresso`).

Limits: XeTeX only; never runs BibTeX (reads the `.bbl` in the folder); up to 32 snapshot processes, killed on exit or
SIGTERM/SIGINT/SIGHUP.
