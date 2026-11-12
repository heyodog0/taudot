# Live pdfTeX

pdfTeX that keeps up with your typing. It retypesets only what follows your edit and gives the **exact** PDF, the
one `pdflatex` would write, usually within milliseconds.

- **Snapshots.** The engine forks a paused copy of itself as it reads the project. An edit kills the run and resumes
  from the last snapshot before the changed byte.
- **Pages early.** Each page is finished into a PDF as soon as it ships, so the page you're on comes first.
- **latexmk's rule built in.** BibTeX, biber, makeindex and reruns happen when their inputs change.
- **Paragraph preview.** While the page is typeset, the edited paragraph alone is set in about a millisecond.
- **TeX Live on demand.** Overleaf's TeX Live years (2024–2026). Files are fetched from a content-addressed store the
  first time a document asks for them.

## Build

```console
$ SERIES=2026 sh clients/pdftex/build.sh live     # TeX Live's release source + patches/2026, out of tree
$ pdftex-live --serve --state STATE DIR main.tex OUT  # JSON on stdin/stdout: docs/live-protocol.md
```

## Docs

- [DESIGN.md](DESIGN.md): the patches, how the engine works, the TeX Live store, latexmk's rule, `--serve`.

Licence: GPL-2.0-or-later, like pdfTeX.
