"""The corpus: arXiv sources in ~/code/lab/taudot-ref/corpus/<id>/ (outside the repo; papers keep their licences),
listed in corpus.toml (in the repo). `scan` finds each paper's main file and feature tags from its sources;
`check` records whether it compiles under Tectonic and under txp-render (texpresso-xetex).

    uv run python corpus.py scan          # (re)write corpus.toml's tags and main files, keeping hand-set fields
    uv run python corpus.py check [ID...] # compile status, page counts
"""

import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

TECTONIC = ["tectonic", "-c", "minimal", "-Z", "continue-on-errors", "--keep-logs"]
HERE = Path(__file__).resolve().parent
CORPUS = Path.home() / "code/lab/taudot-ref/corpus"
BUILD = Path.home() / "code/lab/taudot-ref/corpus-results/build"
MANIFEST = HERE / "corpus.toml"
SMOKE = ["synthetic-page", "synthetic-features", "synthetic-pgf", "synthetic-fonts-by-name", "1706.03762"]   # the smoke corpus: under a minute

# tag: patterns over the paper's .tex sources (comments stripped)
TAGS = {
    "maths": None,   # counted below
    "tikz": r"\\usepackage(\[[^\]]*\])?\{[^}]*\b(tikz|pgfplots)\b|\\begin\{tikzpicture\}",
    "colour": r"\\usepackage(\[[^\]]*\])?\{[^}]*\b(xcolor|color)\b|colorlinks\s*=?\s*true|\\textcolor|\\colorbox",
    "transparency": r"opacity\s*=|\\pgfsetfillopacity|\\pgfsetstrokeopacity|\\transparent|fill opacity",
    "fontspec": r"\\usepackage(\[[^\]]*\])?\{fontspec\}|\\setmainfont",
    "special": r"\\pdfliteral|\\special\s*\{|\\pdfsave|\\pdfrestore",
    "rotated": r"\\rotatebox|\\begin\{(sidewaystable|sidewaysfigure|landscape|turn|rotate)\}|angle\s*=\s*-?\d",
    "two-column": r"\\documentclass\[[^\]]*twocolumn|\\twocolumn\b|IEEEtran|\\usepackage\{(acl|naacl|emnlp|icml\w*|cvpr|iccv)\}|revtex",
}
CLASSES = [("neurips", r"neurips|nips_?\d+"), ("icml", r"icml\d*"), ("iclr", r"iclr\d+"), ("acl", r"\{(acl|naacl|emnlp)\w*\}"),
           ("ieee", r"IEEEtran"), ("cvpr", r"\{(cvpr|iccv)\w*\}"), ("revtex", r"revtex"), ("jmlr", r"jmlr"),
           ("amsart", r"\{amsart\}"), ("book", r"\{(book|report|memoir)\}")]


def strip_comments(s: str) -> str:
    return re.sub(r"(?<!\\)%.*", "", s)


def tex_files(d: Path) -> list[Path]:
    return [p for p in d.rglob("*") if p.suffix in (".tex", ".sty", ".cls") and p.is_file()]


def main_file(d: Path) -> str | None:
    best = None
    for p in d.rglob("*.tex"):
        s = strip_comments(p.read_text(errors="replace"))
        if re.search(r"\\documentclass", s) and r"\begin{document}" in s:
            score = len(s) + (10**7 if p.stem in ("main", "ms", "paper", "arxiv") else 0)
            if best is None or score > best[0]:
                best = (score, p)
    return str(best[1].relative_to(d)) if best else None


def scan_paper(d: Path) -> dict:
    texs = [p for p in d.rglob("*.tex")]
    src = "\n".join(strip_comments(p.read_text(errors="replace")) for p in texs)
    tags = []
    n_math = len(re.findall(r"\\begin\{(equation|align|gather|multline|eqnarray)\*?\}|\$\$|\\\[", src))
    if n_math >= 40:
        tags.append("maths")
    for t, pat in TAGS.items():
        if pat and re.search(pat, src):
            tags.append(t)
    files = [p.suffix.lower() for p in d.rglob("*") if p.is_file()]
    if "\\includepdf" in src:
        tags += ["pdfpages", "pdf-figures"]
    if any(s == ".pdf" for s in files) and "includegraphics" in src:
        tags.append("pdf-figures")
    if any(s in (".png", ".jpg", ".jpeg") for s in files):
        tags.append("raster-figures")
    if any(s == ".eps" for s in files):
        tags.append("eps-figures")
    cls = [name for name, pat in CLASSES if re.search(pat, src[:200000])]
    if cls:
        tags.append("class-" + cls[0])
    if len(src) < 20000 and n_math < 10:
        tags.append("plain-text")
    if len(src) > 300000:
        tags.append("long")
    return {"main": main_file(d), "tags": sorted(set(tags)), "maths_envs": n_math, "tex_bytes": len(src)}


def load() -> dict:
    return tomllib.loads(MANIFEST.read_text())["paper"] if MANIFEST.exists() else {}


def save(papers: dict) -> None:
    def val(v):
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, (int, float)):
            return str(v)
        if isinstance(v, list):
            return "[" + ", ".join(val(x) for x in v) + "]"
        if isinstance(v, dict):
            return "{ " + ", ".join(f"{k} = {val(x)}" for k, x in v.items()) + " }"
        return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'
    out = ["# The fidelity corpus (harness/corpus.py). Sources live outside the repo in ~/code/lab/taudot-ref/corpus/<id>/",
           "# (papers keep their own licences). tags, main, maths_envs, tex_bytes: from `corpus.py scan`; tectonic, txp,",
           "# pages: from `corpus.py check`; note: by hand. Papers that don't compile under texpresso-xetex stay listed.",
           f"smoke = {val(SMOKE)}", ""]
    for k in sorted(papers):
        out.append(f'[paper."{k}"]')
        for f, v in papers[k].items():
            if v is not None:
                out.append(f"{f} = {val(v)}")
        out.append("")
    MANIFEST.write_text("\n".join(out))


def folder(pid: str) -> Path:
    return CORPUS / pid.replace("/", "_")


def scan() -> None:
    papers = load()
    for d in sorted(CORPUS.iterdir()):
        if not d.is_dir() or not ((d / ".fetched").exists() or (d / ".local").exists()):
            continue
        pid = d.name
        old = papers.get(pid, {})
        new = scan_paper(d)
        if not new["main"]:
            new["note"] = old.get("note", "no LaTeX source (" + (d / ".fetched").read_text().strip() + ")") if (d / ".fetched").exists() else old.get("note")
        papers[pid] = {**old, **{k: v for k, v in new.items() if v is not None}}
        if old.get("tags_manual"):
            papers[pid]["tags"] = sorted(set(papers[pid]["tags"]) | set(old["tags_manual"]))
    save(papers)
    print(len(papers), "papers")


def copy_sources(pid: str, dest: Path) -> Path:
    """A fresh copy of the paper's sources at dest, with its source fixes applied (the corpus folder is never written).
    corpus.toml: fix = [{ file = "main.tex", old = "...", new = "...", why = "..." }]: a plain text replacement, each
    `old` found exactly once, for papers that need one to compile under XeTeX at all."""
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(folder(pid), dest, ignore=shutil.ignore_patterns(".fetched", ".local"))
    for f in load().get(pid, {}).get("fix", []):
        p = dest / f["file"]
        t = p.read_text(errors="replace")
        if t.count(f["old"]) != 1:
            raise ValueError(f"{pid}: fix {f['old']!r} found {t.count(f['old'])} times in {f['file']}")
        p.write_text(t.replace(f["old"], f["new"]))
    return dest


def build_dir(pid: str, root: Path = BUILD) -> Path:
    return copy_sources(pid, root / pid)


def use_shipped_bbl(src: Path, main: str) -> bool:
    """arXiv ships the .bbl, not the .bib. Tectonic runs BibTeX anyway, which fails and leaves every citation "?" (a
    shorter paper than TeXpresso's, which reads the .bbl). In the build copy only: \\bibliography{...} → \\input the .bbl."""
    m = src / main
    bbl = m.with_suffix(".bbl")
    if not bbl.exists() or any(src.rglob("*.bib")):
        return False
    t = m.read_text(errors="replace")
    t2, n = re.subn(r"\\bibliography\{[^}]*\}", lambda _: "\\input{" + bbl.name + "}", t)
    if n:
        m.write_text(t2)
    return bool(n)


def check_tectonic(pid: str, main: str, root: Path = BUILD) -> tuple[bool, Path | None]:
    b = build_dir(pid, root) / "tectonic"
    b.parent.joinpath("tectonic").mkdir(exist_ok=True)
    src = b.parent
    use_shipped_bbl(src, main)
    r = subprocess.run([*TECTONIC, "-o", str(b), main], cwd=src, capture_output=True,
                       timeout=900)
    pdf = b / (Path(main).stem + ".pdf")
    (b / "tectonic.out").write_bytes(r.stdout + r.stderr)
    return pdf.exists(), (pdf if pdf.exists() else None)


def check() -> None:
    sys.path.insert(0, str(HERE))
    import raster
    from txp import Txp, TxpError
    papers = load()
    ids = sys.argv[2:] or [k for k, v in papers.items() if v.get("main") and "tectonic" not in v]
    for pid in ids:
        p = papers[pid]
        if not p.get("main"):
            continue
        ok, pdf = check_tectonic(pid, p["main"])
        p["tectonic"] = ok
        if pdf:
            p["pages"] = raster.pdf_pages(pdf)
        b = copy_sources(pid, BUILD / pid / "txp")
        try:
            with Txp(b / p["main"], BUILD / pid / "txp.log") as x:
                ev = x.typeset(timeout=600)
                p["txp"] = ev["n"] > 0
                p["txp_pages"] = ev["n"]
                if x.errors:
                    p["txp_errors"] = len(x.errors)
        except (TxpError, Exception) as e:
            p["txp"] = False
            p["note"] = f"txp-render: {e}"[:200]
        print(pid, "tectonic", p["tectonic"], p.get("pages"), "txp", p.get("txp"), p.get("txp_pages"), flush=True)
        save(papers)


if __name__ == "__main__":
    {"scan": scan, "check": check}[sys.argv[1]]()
