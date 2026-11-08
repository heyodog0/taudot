# pdfsource

Recovers a paper's LaTeX from its PDF and **proves** each paragraph. A paragraph counts as proven when pdfLaTeX,
typesetting the recovered text, puts the same glyphs on the same lines at the same positions, to the scaled point.
It uses no machine learning and no guessing that isn't checked.

- **Reads** glyphs, fonts and pdfTeX's exact positions from the PDF.
- **Recovers** fonts (from `pdftex.map` and TFMs), layout (lines, columns, paragraphs) and the text, including
  inline math, lists, footnotes and citations.
- **Proves** each paragraph by typesetting it again with stock TeX Live, then repairs and retries what doesn't
  match.

On 32 arXiv papers: about half of body lines and words are proven exact, and 96% of paragraphs on the best paper.

## Use

```console
$ cargo build --release
$ pdfsource prove paper.pdf        # a verdict and reason for each paragraph
$ pdfsource tex paper.pdf          # the recovered LaTeX
```

## Docs

- [docs/pdfsource.md](../../docs/pdfsource.md): the method, the measurements, what's not covered yet.
