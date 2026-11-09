# Taudot for Mac

The app: an editor, the live PDF beside it and a review margin, all drawn natively (Swift, AppKit, Metal, no
third-party packages).

- **Two editors.** A native one that works like Overleaf's, or your own Neovim, embedded with your config. Both
  scroll by the pixel.
- **The PDF beside it** follows as you type: the live pdfTeX, the universal engine for XeLaTeX and LuaLaTeX, or
  TeXpresso. Click a word to jump to its source, and the other way.
- **Review margin.** Overleaf's comments as cards next to your text: reply, resolve, or comment on a selection or
  on the PDF.
- **Projects window**, Settings, themes and an issues panel for the log's errors.

## Build

```console
$ cd clients/mac
$ swift build && swift test
$ sh bundle.sh                     # build.noindex/Taudot.app
```

`./install.sh` at the repo root builds this with everything else.

## Docs

- [docs/mac-app.md](../../docs/mac-app.md): how the app is built.
