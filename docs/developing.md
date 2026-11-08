# Developing Taudot

What a fresh clone needs beyond `./install.sh`, and which tests need what. Paths below are relative to your clone.

## Builds and tests that need nothing else

```console
$ cargo test --workspace            # the engine, the Overleaf client and the OT core; no network, no Overleaf
$ cd clients/mac && swift build      # the app
```

`swift test` (in `clients/mac`) runs the in-process tests. Tests of the live pdfTeX and the paragraph preview look
for the reference builds below (`TAUDOT_REF`).

## Local Overleaf CE (the CE tests)

The scripts under `crates/engine/tests/ce/`, `clients/nvim/tests/ce_*.sh`, `clients/mac/Tests/*_ce.sh`,
`harness/` and `site/demo/` talk to an Overleaf Community Edition in Docker:

```console
$ docker/up.sh                       # starts CE on http://localhost:8800, creates the test users
$ export TAUDOT_ENV_FILE=$PWD/docker/.env.test
```

`docker/up.sh` writes the test users' credentials to `docker/.env.test` (gitignored). Most scripts default to the
maintainer's checkout (`~/code/lab/taudot/docker/.env.test`), so set `TAUDOT_ENV_FILE` as above. The review-thread
routes need `harness/ce-threads/install.sh` (again after the container is recreated).

These tests are maintainer-only: the long-review-panel tests run on a replica of a real paper that is not in the
repository (`harness/replicate.ts`, snapshot in `~/.taudot/replicas/`).

## Reference checkouts and builds (`TAUDOT_REF`)

Large inputs live outside the repository, in one folder that the scripts call the reference folder. It defaults to
`~/code/lab/taudot-ref` (the maintainer's layout). Put yours anywhere and point the variables at it:

| Variable | Used by | Default | What goes there |
|---|---|---|---|
| `TAUDOT_REF` | `TaudotPDF/LiveTex.swift`, `ParaOverlayTests.swift`, `clients/pdftex/tests/conftest.py` | `~/code/lab/taudot-ref` | the folder itself |
| `PDFTEX_REF` | `clients/mac/bundle.sh` | `~/code/lab/taudot-ref` | `pdftex-build-<year>/`, `texlive-<year>/store-root/` |
| `SRC`, `BUILD`, `SERIES` | `clients/pdftex/build.sh` | `$REF/texlive-<year>/src`, `$REF/pdftex-build-<year>` | TeX Live's source and the live pdfTeX build (`clients/pdftex/README.md`) |
| `BUILD`, `TEXLIVE`, `TAUDOT_TEXMF`, `WORK` | `clients/pdftex/bench.py` | `$REF/pdftex-build[-<year>]`, `$REF/pdftex-texmf` | bench inputs |
| `BIBTEX_BIN` | `clients/mac/bundle.sh` | `$REF/pdftex-build-2025/stock/texk/web2c/bibtex` | TeX Live's BibTeX |
| `TEXPRESSO_DIR` | `install.sh`, `bundle.sh`, `clients/render/build.sh`, `clients/preview/texpresso/build.sh`, render harness | `vendor/texpresso` (made by `install.sh`), else `$REF/texpresso` | upstream TeXpresso with our patches |
| `TEXPRESSO_XETEX` | `clients/render/tests/conftest.py`, `clients/preview/texpresso/*.ts`, `TaudotPDF/Txp.swift` | `$REF/texpresso/build/texpresso-xetex` | the engine binary; the app first looks in its bundle; `vendor/texpresso/build/texpresso-xetex` after `install.sh` |
| `TEXSTORE_REF` | `tools/texstore/` | `$REF/texstore` | maintainer-only: builds the TeX Live store |
| none (fixed path) | `clients/render/harness/*.py`, `clients/render/fonts/tests/collect.py` | `$REF/corpus`, `$REF/corpus-results` | the renderer's arXiv fidelity corpus (`clients/render/harness/fetch.py <arXiv id>`) |

Without the live pdfTeX builds the app still works: `bundle.sh` notes what it skipped, and pdfLaTeX projects use
TeXpresso for the preview.

## The TeX Live store

The live pdfTeX fetches TeX Live files on demand from `https://texlive.taudot.app` (public, read-only; see
`docs/texstore.md`). `TEXSTORE_URL` points it at another copy (`LiveTex.swift`, `clients/pdftex/texlive/tl.py`).

## Performance scripts

`clients/mac/Tests/perf/run.sh`, `pdf_latency.sh` and `pdf_typing.sh` need a long LaTeX project (a `main.tex` of
400+ lines; the scripts jump to fixed lines). Pass it as `-d DOC` / `FOLDER`, or set `TAUDOT_PERF_DOC`. The
folder is copied before every run and never written.

## A fork's own release

A fork that ships builds must change the update feed (`taudot.app/updates/appcast.xml` in `clients/mac/bundle.sh`
and `TaudotApp/Updater.swift`) and the Sparkle key (`TAUDOT_ED_PUBLIC_KEY`), and must use a different name (see
`NOTICE`). `docs/release.md` has the steps.
