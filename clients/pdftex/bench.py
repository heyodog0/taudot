# GPL-2.0-or-later. Phase 1 benchmark for the live pdfTeX: correctness, latency, finish cost, memory.
#
#   uv run clients/pdftex/bench.py fmt                     build pdflatex.fmt for the stock and live engines
#   uv run clients/pdftex/bench.py run NAME SRC MAIN [--snapshot-ms N ...]
#        copies SRC (never the original) into the scratch dir, settles its .aux with stock pdfLaTeX, writes
#        scripted edits (preamble, start, middle, end, \cite, \ref), runs the live driver, and checks each final
#        live PDF against a from-scratch stock run of the edited copy
#   uv run clients/pdftex/bench.py finish NAME             fork-to-finish after every page of NAME (cost vs pages)
#
# TEXLIVE=2026|2025|2024: Overleaf's TeX Live image of that year from the TeX Live store, files fetched on demand by
# kpathsea (texlive/tl.py; run `tl.py store YEAR` first; TAUDOT_TL_SOURCE=iso and `tl.py setup 2025`: 2025's release
# ISO), engines built from the year's series and run as `pdflatex`, the format built as fmtutil builds it.
# Unset: Phase 1's setup (Tectonic's bundle, the trunk engines).
# Paths: BUILD (~/code/lab/taudot-ref/pdftex-build[-YEAR]), TAUDOT_TEXMF (~/code/lab/taudot-ref/pdftex-texmf),
# WORK (where copies and outputs go; set it to your scratchpad). Paper content never goes into the repo.
import filecmp
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.expanduser("~/code/lab/taudot-ref")
YEAR = os.environ.get("TEXLIVE")
BUILD = os.environ.get("BUILD", f"{REF}/pdftex-build" + (f"-{YEAR}" if YEAR else ""))
TEXMF = os.environ.setdefault("TAUDOT_TEXMF", f"{REF}/pdftex-texmf")
WORK = os.environ.get("WORK") or sys.exit("set WORK (a scratch directory)")
ENGINES = {k: f"{BUILD}/{k}/texk/web2c/" + ("pdflatex" if YEAR else "pdftex") for k in ("stock", "live")}
if YEAR:
    sys.path.insert(0, f"{HERE}/texlive")
    import tl
    TL = tl.source(YEAR)
    for k in ENGINES:  # progname pdflatex: kpathsea's TEXINPUTS.pdflatex, as on Overleaf
        if os.path.exists(f"{BUILD}/{k}/texk/web2c/pdftex") and not os.path.lexists(ENGINES[k]):
            os.symlink("pdftex", ENGINES[k])
DRIVER = f"{BUILD}/pdftex-live"
BIBTEX = f"{BUILD}/stock/texk/web2c/bibtex" if os.path.exists(f"{BUILD}/stock/texk/web2c/bibtex") else None
# biber and makeindex: the year's TeX Live binaries (svn, bin/universal-darwin at the image's revision)
TOOLS = f"{REF}/tools-{YEAR}" if YEAR else None
BIBER = f"{TOOLS}/biber" if TOOLS and os.path.exists(f"{TOOLS}/biber") else None
MAKEINDEX = f"{TOOLS}/makeindex" if TOOLS and os.path.exists(f"{TOOLS}/makeindex") else None
MAKEGLOSSARIES = None  # set in main: TeX Live's script, fetched into the year's tree
IDXSTATE = ".taudot-idxstate"  # inputs of makeindex/makeglossaries at their last run (latexmk's fdb)


def idx_rules(d, stem):
    """(input, output, glossary?) pairs: .idx -> .ind; each \\@newglossary{type}{log}{out}{in} in the .aux."""
    out = [(f"{stem}.idx", f"{stem}.ind", False)] if MAKEINDEX else []
    if MAKEGLOSSARIES:
        out += [(f"{stem}.{i}", f"{stem}.{o}", True) for _, _, o, i in
                re.findall(r"\\@newglossary\{([^}]*)\}\{([^}]*)\}\{([^}]*)\}\{([^}]*)\}", read(f"{d}/{stem}.aux") or "")]
    return out


def idx_state(d, stem):
    st = {}
    for line in (read(f"{d}/{IDXSTATE}") or "").splitlines():
        k, _, v = line.partition("=")
        st[k] = v
    return st


def idx_init(d, stem):
    """The outputs on disk are current for their inputs (a settled project)."""
    st = {i: md5(f"{d}/{i}") for i, o, _ in idx_rules(d, stem) if os.path.exists(f"{d}/{o}")}
    open(f"{d}/{IDXSTATE}", "w").write("".join(f"{k}={v}\n" for k, v in st.items()))
EPOCH = "1700000000"
SYNCTEX = os.environ.get("SYNCTEX")  # "1": -synctex=1 on every run (as Overleaf), and the .synctex.gz checked too


def env(kind):
    e = dict(os.environ)
    if YEAR:
        e.update(TL.env(f"{BUILD}/fmt-{kind}"), SOURCE_DATE_EPOCH=EPOCH, FORCE_SOURCE_DATE="1")
        for k in ("TAUDOT_LIVE_FD", "KPATHSEA_DEBUG", "TAUDOT_TEXMF", "TEXINPUTS"):
            e.pop(k, None)
        return e
    e.update(TEXMFCNF=f"{HERE}/texmf", TAUDOT_TEXMF=TEXMF, TAUDOT_FMT=f"{BUILD}/fmt-{kind}",
             SOURCE_DATE_EPOCH=EPOCH, FORCE_SOURCE_DATE="1",
             MKTEXTEX="0", MKTEXTFM="0")  # no fetching in timed runs; fetch_learn turns it on
    e["PATH"] = f"{HERE}/texmf/bin:" + e["PATH"]  # mktextex: fetch missing files from the bundle
    for k in ("TAUDOT_LIVE_FD", "KPATHSEA_DEBUG"):
        e.pop(k, None)
    return e


def fetch_learn(cmd, kind, cwd):
    if YEAR:
        return  # kpathsea fetches what it needs
    subprocess.run(["uv", "run", "--no-project", f"{HERE}/texmf/fetch.py", "--learn", "--", *cmd], cwd=cwd,
                   env={**env(kind), "MKTEXTEX": "1", "MKTEXTFM": "1"}, check=False)


def fmt():
    if not YEAR:
        os.makedirs(TEXMF, exist_ok=True)
        for f in ("pdftexconfig.tex", "language.dat"):
            shutil.copy(f"{HERE}/texmf/{f}", TEXMF)
    for kind, exe in ENGINES.items():
        d = f"{BUILD}/fmt-{kind}"
        os.makedirs(d, exist_ok=True)
        if YEAR:  # fmtutil.cnf's line: pdflatex pdftex language.dat -translate-file=cp227.tcx *pdflatex.ini
            cmd = [f"{BUILD}/{kind}/texk/web2c/pdftex", "-ini", "-jobname=pdflatex", "-progname=pdflatex",
                   "-translate-file=cp227.tcx", "*pdflatex.ini"]
        else:
            cmd = [exe, "-ini", "-etex", "-jobname=pdflatex", "-interaction=nonstopmode",
                   "-translate-file=cp227.tcx", "*pdflatex.ini"]
        fetch_learn(cmd, kind, d)
        t = time.time()
        r = subprocess.run(cmd, cwd=d, env=env(kind), capture_output=True, text=True, errors="replace",
                           stdin=subprocess.DEVNULL)
        print(f"fmt {kind}: exit {r.returncode}, {time.time() - t:.1f} s, "
              f"{os.path.getsize(d + '/pdflatex.fmt') if os.path.exists(d + '/pdflatex.fmt') else 0} bytes")
        if r.returncode:
            print(r.stdout[-3000:])


def pdflatex(kind, d, main, recorder=False):
    t = time.monotonic()
    r = subprocess.run([ENGINES[kind], "-fmt=pdflatex", "-interaction=batchmode", *(["-recorder"] if recorder else []),
                        *([f"-synctex={SYNCTEX}"] if SYNCTEX else []), main], cwd=d, env=env(kind),
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode, (time.monotonic() - t) * 1000


BIB = re.compile(r"^\\(?:citation|bibdata|bibstyle)\{.*$", re.M)


def bib_lines(aux):
    return "\n".join(BIB.findall(aux or ""))


def bib_state(d, stem):
    """The bib lines of the main .aux and of every .aux it \\@inputs (\\include'd chapters), as BibTeX reads them."""
    out, todo, seen = [], [f"{stem}.aux"], set()
    while todo:
        a = todo.pop(0)
        if a in seen:
            continue
        seen.add(a)
        t = read(f"{d}/{a}")
        if t is None:
            continue
        out.append(bib_lines(t))
        todo += re.findall(r"\\@input\{([^}]+)\}", t)
    return "\n".join(out)


def bib_sources(d, bl):
    """md5s of the \\bibdata .bib files: latexmk reruns BibTeX when one changed since its last run (its fdb file)."""
    names = [b.strip() for m in re.findall(r"\\bibdata\{([^}]*)\}", bl) for b in m.split(",")]
    return ",".join(f"{n}={md5(f'{d}/{n if n.endswith(chr(46) + 'bib') else n + chr(46) + 'bib'}')}" for n in names)


BIBSTATE = ".taudot-bibstate"
BIBERSTATE = ".taudot-biberstate"  # the same for biber: the .bcf and its datasources at the last biber run  # the reference's record of the .bib files at its last BibTeX run (latexmk's fdb)


def read(p):
    try:
        return open(p, "rb").read().decode("latin-1")
    except OSError:
        return None


def latexmk(d, main, max_runs=5):
    """latexmk's loop on stock pdfLaTeX, from latexmk's method rather than the driver's code: after each run, files
    the run read (-recorder's INPUT lines) that a run generated and that changed since the run started, or that
    the log says didn't exist ("No file X."), trigger another run; BibTeX runs when the .aux's bib lines changed
    (or there's \\bibdata and no .bbl), and only if a .bib exists ($bibtex_use = 1). Returns (runs, bibtex runs, ms)."""
    stem = main[:-4]
    runs = bibs = 0
    total = 0.0

    def biber_sources():
        bcf = read(f"{d}/{stem}.bcf") or ""
        return f"bcf={md5(f'{d}/{stem}.bcf')}," + ",".join(
            f"{n}={md5(f'{d}/{n}')}" for n in re.findall(r"<bcf:datasource[^>]*>([^<]+)</bcf:datasource>", bcf))

    def biber_if_needed():
        """latexmk's biber rule: the .bcf or a datasource it names changed since the last biber run, or no .bbl."""
        nonlocal bibs
        src = biber_sources()
        if os.path.exists(f"{d}/{stem}.bbl") and src == (read(f"{d}/{BIBERSTATE}") or ""):
            return False
        before = md5(f"{d}/{stem}.bbl")
        subprocess.run([BIBER, stem], cwd=d, env=env("stock"), stdin=subprocess.DEVNULL, capture_output=True)
        open(f"{d}/{BIBERSTATE}", "w").write(src)
        bibs += 1
        return md5(f"{d}/{stem}.bbl") != before

    def bibtex_if_needed(old_state):
        """latexmk's BibTeX rule: its sources (the .aux files' bib lines, the .bib files) changed, or no .bbl."""
        nonlocal bibs
        if BIBER and os.path.exists(f"{d}/{stem}.bcf"):  # biblatex with biber: latexmk runs biber instead
            return biber_if_needed()
        bl = bib_state(d, stem)
        bibfiles = [b.strip() for m in re.findall(r"\\bibdata\{([^}]*)\}", bl) for b in m.split(",")]
        if not (BIBTEX and "\\bibdata{" in bl and any(
                os.path.exists(f"{d}/{b if b.endswith('.bib') else b + '.bib'}") for b in bibfiles)):
            return False
        src = bib_sources(d, bl)
        if os.path.exists(f"{d}/{stem}.bbl") and bl == old_state and src == (read(f"{d}/{BIBSTATE}") or src):
            return False
        before = md5(f"{d}/{stem}.bbl")
        subprocess.run([BIBTEX, stem], cwd=d, env=env("stock"), stdin=subprocess.DEVNULL, capture_output=True)
        open(f"{d}/{BIBSTATE}", "w").write(src)
        bibs += 1
        return md5(f"{d}/{stem}.bbl") != before

    # an edit to a .bib alone: BibTeX (biber) first, and pdfLaTeX only if the .bbl changed (latexmk's order)
    if BIBER and os.path.exists(f"{d}/{stem}.bcf") and os.path.exists(f"{d}/{BIBERSTATE}"):
        if biber_sources() != read(f"{d}/{BIBERSTATE}") and not biber_if_needed():
            return 0, bibs, 0.0
    elif os.path.exists(f"{d}/{BIBSTATE}") and bib_sources(d, bib_state(d, stem)) != read(f"{d}/{BIBSTATE}"):
        if not bibtex_if_needed(bib_state(d, stem)):
            return 0, bibs, 0.0
    while runs < max_runs:
        before = {}
        for root, _, files in os.walk(d):
            for n in files:
                f = os.path.relpath(os.path.join(root, n), d)
                before[f] = md5(os.path.join(d, f))
        old_state = bib_state(d, stem)
        code, ms = pdflatex("stock", d, main, recorder=True)
        runs += 1
        total += ms
        fls = read(f"{d}/{stem}.fls") or ""
        rel = lambda x: os.path.relpath(os.path.join(d, x), d) if not x.startswith("/") else os.path.relpath(x, d)
        inputs = {rel(l[6:]) for l in fls.splitlines() if l.startswith("INPUT ")}
        outputs = {rel(l[7:]) for l in fls.splitlines() if l.startswith("OUTPUT ")}
        inputs = {f for f in inputs if not f.startswith("..")}
        bibtex_if_needed(old_state)
        outputs.add(f"{stem}.bbl")
        # makeindex, makeglossaries (Overleaf's latexmkrc): an input changed since its program's last run, or no output
        st, gl_done = idx_state(d, stem), False
        rules = idx_rules(d, stem)
        for i, o, gl in rules:
            if not os.path.exists(f"{d}/{i}") or (os.path.exists(f"{d}/{o}") and st.get(i) == md5(f"{d}/{i}")):
                continue
            if not gl:
                subprocess.run([MAKEINDEX, "-o", o, i], cwd=d, env=env("stock"), stdin=subprocess.DEVNULL, capture_output=True)
            elif not gl_done:
                subprocess.run(["perl", MAKEGLOSSARIES, stem], cwd=d, stdin=subprocess.DEVNULL, capture_output=True,
                               env={**env("stock"), "PATH": os.path.dirname(MAKEINDEX) + ":" + os.environ["PATH"]})
                gl_done = True
            bibs += 1
            for i2, _, g2 in rules:
                if g2 == gl:
                    st[i2] = md5(f"{d}/{i2}")
            outputs.add(o)
        open(f"{d}/{IDXSTATE}", "w").write("".join(f"{k}={v}\n" for k, v in st.items()))
        log = read(f"{d}/{stem}.log") or ""
        missing = {m for m in re.findall(r"^No file (.+)\.$", log, re.M) if os.path.exists(f"{d}/{m}")}
        changed = {f for f in inputs & outputs if md5(f"{d}/{f}") != before.get(f)} | missing
        if not changed:
            break
    return runs, bibs, total


def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest() if os.path.exists(p) else None


def settle(d, main):
    """Stock runs until the .aux stops changing (at most 4), as latexmk would without BibTeX."""
    if YEAR:
        runs, bibs, ms = latexmk(d, main)
        print(f"  settle (latexmk loop): {runs} runs, {bibs} bibtex, {ms:.0f} ms")
        return
    stem = main[:-4]
    fetch_learn([ENGINES["stock"], "-fmt=pdflatex", "-interaction=batchmode", main], "stock", d)
    had_bbl = os.path.exists(f"{d}/{stem}.bbl")  # arXiv sources ship one, often without the .bib
    prev = None
    for i in range(4):
        if i == 1 and not had_bbl and "\\bibdata" in open(f"{d}/{stem}.aux", errors="replace").read():
            r = subprocess.run([f"{BUILD}/stock/texk/web2c/bibtex", stem], cwd=d, env=env("stock"),
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace")
            print(f"  bibtex: exit {r.returncode}")
            fetch_learn([ENGINES["stock"], "-fmt=pdflatex", "-interaction=batchmode", main], "stock", d)
        code, ms = pdflatex("stock", d, main)
        cur = md5(f"{d}/{stem}.aux")
        print(f"  settle run {i + 1}: exit {code}, {ms:.0f} ms")
        if cur == prev:
            break
        prev = cur


def load():
    return " ".join(f"{x:.2f}" for x in os.getloadavg())


# ---- scripted edits ----

def esc(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def make_edits(d, main):
    """Edits at the preamble, start, middle and end of the body, and in a \\cite and a \\ref. Chosen from the
    copy's own text, so nothing about the paper is committed."""
    src = open(f"{d}/{main}", encoding="utf-8", errors="replace").read()
    b = src.index("\\begin{document}")
    e = src.rfind("\\end{document}")
    bib = src.rfind("\\bibliography", b, e)
    end_body = bib if bib > 0 else e
    lines, after = [], []   # (file, line), in reading order; \\input files are followed one level down
    plain = re.compile(r"[A-Za-z][a-z]+ [a-z]+ [a-z]+ ")
    texts = {main: src}

    def scan(fname, text, lo, hi, pool):
        pos = 0
        for ln in text.splitlines(keepends=True):
            if lo <= pos < hi:
                m = re.match(r"\s*\\(?:input|include)\{([^}]+)\}", ln)
                sub = m and (m.group(1) if m.group(1).endswith(".tex") else m.group(1) + ".tex")
                if sub and os.path.exists(f"{d}/{sub}") and fname == main:
                    t = open(f"{d}/{sub}", encoding="utf-8", errors="replace").read()
                    texts[sub] = t
                    scan(sub, t, 0, len(t), pool)
                elif plain.match(ln) and len(ln) > 60 and text.count(ln) == 1:
                    pool.append((fname, ln))
            pos += len(ln)

    scan(main, src, b, end_body, lines)
    scan(main, src, end_body, e, after)
    if not lines:
        sys.exit("no plain text lines found")
    out = []
    pre = src[:b]
    dc = re.search(r"\\documentclass[^\n]*\n", pre)
    anchor = dc.group(0)
    out.append(("preamble", main, anchor, anchor + "\\newcommand{\\taudotprobe}{probe}\n"))

    def word_edit(label, frac, pool=lines):
        fname, ln = pool[min(int(frac * len(pool)), len(pool) - 1)]
        w = ln.split(" ")
        new = " ".join(w[:3] + ["taudot edit here"] + w[3:])
        out.append((label, fname, ln, new))

    word_edit("start", 0.02)
    word_edit("middle", 0.5)
    word_edit("end", 0.97)
    new = []
    if YEAR:  # Phase 3: edits that change the .aux (reruns) and the citations (BibTeX)
        fname, ln = lines[min(int(0.6 * len(lines)), len(lines) - 1)]
        out.append(("fwdref", fname, ln, ln.rstrip("\n") + " See Section~\\ref{sec:taudotprobe}.\n"))
        fname, ln = lines[min(int(0.3 * len(lines)), len(lines) - 1)]
        out.append(("newsec", fname, ln, "\\section{Taudot probe}\\label{sec:taudotprobe}\n" + ln))
        bibs = re.findall(r"\\bibliography\{([^}]+)\}", src) or re.findall(r"\\addbibresource\{([^}]+)\}", src)
        bkeys = []
        for bn in (bibs[0].split(",") if bibs else []):
            bp = f"{d}/{bn.strip()}" + ("" if bn.strip().endswith(".bib") else ".bib")
            if os.path.exists(bp):
                bkeys += re.findall(r"@\w+\s*\{\s*([^,\s]+)\s*,", open(bp, errors="replace").read())
        cited = set(k.strip() for c in re.findall(r"\\cite\w*\{([^}]+)\}", "".join(texts.values())) for k in c.split(","))
        new = [k for k in bkeys if k not in cited]
        if new:
            fname, ln = lines[min(int(0.4 * len(lines)), len(lines) - 1)]
            out.append(("newcite", fname, ln, ln.rstrip("\n") + " \\citep{" + new[0] + "}.\n"))
    if YEAR:  # edits to the .bib alone: a cited entry (BibTeX, the .bbl changes, a rerun) and an uncited one (none)
        aux = read(f"{d}/{main[:-4]}.aux") or ""
        cited_aux = {k.strip() for c in re.findall(r"\\citation\{([^}]+)\}", aux) for k in c.split(",")}
        cited_aux |= set(re.findall(r"<bcf:citekey[^>]*>([^<]+)</bcf:citekey>", read(f"{d}/{main[:-4]}.bcf") or ""))
        cited_aux |= set(new[:1])  # newcite's key is cited by then
        for subaux in re.findall(r"\\@input\{([^}]+)\}", aux):
            cited_aux |= {k.strip() for c in re.findall(r"\\citation\{([^}]+)\}", read(f"{d}/{subaux}") or "")
                          for k in c.split(",")}
        for bn in (re.findall(r"\\bibliography\{([^}]+)\}", src) or re.findall(r"\\addbibresource\{([^}]+)\}", src)
                   or [""])[0].split(","):
            bn = bn.strip()
            bf = bn if bn.endswith(".bib") else bn + ".bib"
            if not bn or not os.path.exists(f"{d}/{bf}"):
                continue
            bt = open(f"{d}/{bf}", encoding="utf-8", errors="surrogateescape").read()
            texts[bf] = bt
            for label, want in (("bibcited", True), ("bibuncited", False)):
                for m in re.finditer(r"@\w+\s*\{\s*([^,\s]+)\s*,", bt):
                    if (m.group(1) in cited_aux) != want:
                        continue
                    t = re.compile(r"\btitle\s*=\s*[{\"]", re.I).search(bt, m.end())
                    nxt = bt.find("@", m.end())
                    if t and (nxt < 0 or t.start() < nxt):
                        line = bt[t.start():bt.index("\n", t.end()) + 1]
                        if bt.count(line) == 1:
                            out.append((label, bf, line, line[:t.end() - t.start()] + "Taudot " + line[t.end() - t.start():]))
                            break
            break
    if YEAR and "\\makeindex" in src:  # a new index entry: .idx changes, makeindex, rerun
        fname, ln = lines[min(int(0.45 * len(lines)), len(lines) - 1)]
        out.append(("newindex", fname, ln, ln.rstrip("\n") + "\\index{Taudotprobe}\n"))
    if YEAR and "\\makeglossaries" in src:  # an entry used for the first time: .glo changes, makeglossaries, rerun
        defined = re.findall(r"\\newglossaryentry\{([^}]+)\}", src)
        used = set(re.findall(r"\\[gG]ls(?:pl)?\{([^}]+)\}", "".join(texts.values())))
        fresh = [k for k in defined if k not in used]
        if fresh:
            fname, ln = lines[min(int(0.55 * len(lines)), len(lines) - 1)]
            out.append(("newgls", fname, ln, ln.rstrip("\n") + " \\gls{" + fresh[0] + "}.\n"))
    cites = re.findall(r"\\cite[pt]?\{([^}]+)\}", src[b:])
    keys = []
    for c in cites:
        for k in c.split(","):
            if k.strip() not in keys:
                keys.append(k.strip())
    m = re.search(r"\\cite[pt]?\{([^},]+)\}", src[b + len(src[b:]) // 2:])
    if m and len(keys) > 1:
        old = m.group(0)
        other = next(k for k in keys if k != m.group(1).strip())
        out.append(("cite", main, old, old.replace(m.group(1), other)))
    labels = re.findall(r"\\label\{([^}]+)\}", src)
    m = re.search(r"\\ref\{([^}]+)\}", src[b + len(src[b:]) // 2:])
    if m and len(labels) > 1:
        old = m.group(0)
        other = next(k for k in labels if k != m.group(1))
        out.append(("ref", main, old, old.replace(m.group(1), other)))
    for k in range(1, 10):
        word_edit(f"body{k * 10}", k / 10 + 0.03)
    if after:
        for k in (0.2, 0.5, 0.95):
            word_edit(f"after-bib{int(k * 100)}", k, after)
    # keep only edits that still apply, in order, to the text the earlier edits left
    kept = []
    for label, fname, s, r in out:
        t = texts[fname]
        if s in t:
            i = t.index(s)
            texts[fname] = t[:i] + r + t[i + len(s):]
            kept.append((label, fname, s, r))
    with open(f"{d}.edits", "w") as f:
        for label, fname, s, r in kept:
            f.write(f"{label}\t{fname}\t{esc(s)}\t{esc(r)}\n")
    return kept


def apply_edit(d, fname, s, r):
    p = f"{d}/{fname}"
    t = open(p, encoding="utf-8", errors="surrogateescape").read()
    i = t.index(s)
    open(p, "w", encoding="utf-8", errors="surrogateescape").write(t[:i] + r + t[i + len(s):])


def pdf_text_positions(p):
    """Text with positions, for when bytes differ. Uses pypdf via uv (a test-only dependency)."""
    code = ("import sys,pypdf\nr=pypdf.PdfReader(sys.argv[1])\nprint(len(r.pages))\n"
            "for pg in r.pages:\n  out=[]\n  pg.extract_text(visitor_text=lambda t,cm,tm,fd,fs: out.append((round(tm[4],1),"
            "round(tm[5],1),t)) if t.strip() else None)\n  print(out)\n")
    r = subprocess.run(["uv", "run", "--no-project", "--with", "pypdf", "python", "-I", "-c", code, p],
                       capture_output=True, text=True)
    return r.stdout


def synctex_same(a, adir, b, bdir):
    """The two .synctex.gz files say the same, once each run's directory is replaced by one placeholder (and the
    byte-count records that depend on its length are left out)."""
    import gzip
    try:
        ta = gzip.decompress(open(a, "rb").read()).replace(os.path.realpath(adir).encode(), b"DIR")
        tb = gzip.decompress(open(b, "rb").read()).replace(os.path.realpath(bdir).encode(), b"DIR")
    except OSError:
        return False
    ta = ta.replace(adir.encode(), b"DIR")
    tb = tb.replace(bdir.encode(), b"DIR")
    # a reference that didn't run (a .bib edit with the same .bbl) keeps the previous reference's file
    tb = re.sub(re.escape(os.path.dirname(bdir)).encode() + rb"/ref-[0-9]+", b"DIR", tb)
    # "!N" records count the bytes written since the last one, so they shift with the directory name's length;
    # the byte-for-byte check in the same directory covers them
    drop = re.compile(rb"^![0-9]+\n", re.M)
    return drop.sub(b"", ta) == drop.sub(b"", tb)


def run(name, src, main, extra):
    base = f"{WORK}/{name}/base"
    if not os.path.exists(base):
        os.makedirs(os.path.dirname(base), exist_ok=True)
        shutil.copytree(src, base, symlinks=False)
        print(f"{name}: settling {base}")
        settle(base, main)
    stem = main[:-4]
    if YEAR and not os.path.exists(f"{base}/{BIBSTATE}"):  # the settled .bbl is current for the .bib as it is
        open(f"{base}/{BIBSTATE}", "w").write(bib_sources(base, bib_state(base, stem)))
    if YEAR and BIBER and os.path.exists(f"{base}/{stem}.bcf") and not os.path.exists(f"{base}/{BIBERSTATE}"):
        bcf = read(f"{base}/{stem}.bcf")
        open(f"{base}/{BIBERSTATE}", "w").write(f"bcf={md5(f'{base}/{stem}.bcf')}," + ",".join(
            f"{n}={md5(f'{base}/{n}')}" for n in re.findall(r"<bcf:datasource[^>]*>([^<]+)</bcf:datasource>", bcf)))
    if YEAR and not os.path.exists(f"{base}/{IDXSTATE}"):
        idx_init(base, stem)
    edits = make_edits(base, main)
    code, full_ms = pdflatex("stock", base, main)
    print(f"{name}: stock full run {full_ms:.0f} ms (exit {code}), load {load()}")
    # references: base plus edits 1..i, from scratch
    refs = []
    prev = base
    for i in range(len(edits)):
        rd = f"{WORK}/{name}/ref-{i + 1}"
        shutil.rmtree(rd, ignore_errors=True)
        if YEAR:  # as Overleaf compiles: the previous compile's outputs, this edit, latexmk's loop
            shutil.copytree(prev, rd)
            apply_edit(rd, *edits[i][1:])
            runs, bibs, ms = latexmk(rd, main)
            prev = rd
            refs.append((rd, ms, runs, bibs))
            continue
        shutil.copytree(base, rd)
        for label, fname, s, r in edits[:i + 1]:
            apply_edit(rd, fname, s, r)
        code, ms = pdflatex("stock", rd, main)
        refs.append((rd, ms, 1, 0))
    live = f"{WORK}/{name}/live"
    out = f"{WORK}/{name}/out"
    shutil.rmtree(live, ignore_errors=True)
    shutil.rmtree(out, ignore_errors=True)
    shutil.copytree(base, live)
    print(f"{name}: live run, load {load()}")
    r = subprocess.run([DRIVER, "--engine", ENGINES["live"], *(["--bibtex", BIBTEX] if YEAR and BIBTEX else []),
                        *(["--biber", BIBER] if BIBER else []),
                        *(["--makeindex", MAKEINDEX] if MAKEINDEX else []),
                        *(["--makeglossaries", MAKEGLOSSARIES] if MAKEGLOSSARIES else []),
                        *(["--synctex", SYNCTEX] if SYNCTEX else []), *extra, live, main, f"{base}.edits", out],
                       env={**env("live")}, capture_output=True, text=True)
    print(r.stdout)
    open(f"{WORK}/{name}/driver.tsv", "w").write(r.stdout)
    if r.stderr:
        print(r.stderr[-2000:])
    # correctness
    first = f"{out}/final-0.pdf"
    print(f"check first run: live {'==' if filecmp.cmp(first, base + '/' + stem + '.pdf', shallow=False) else '!='} stock")
    ok = True
    finals = {int(l.split("\t")[1]): l.split("\t") for l in r.stdout.splitlines()
              if l.startswith("edit\t") and l.split("\t")[1].isdigit()}
    seqs = sorted(finals)
    for i, (rd, ms, rruns, rbibs) in enumerate(refs):
        row = finals[seqs[i]] if i < len(seqs) else None
        lp = row[-1] if row and len(row) > 17 else f"{out}/final-{i + 1}.pdf"
        live_runs = f", live {row[14]} runs {row[15]} bibtex" if row and len(row) > 17 else ""
        rp = f"{rd}/{stem}.pdf"
        if not os.path.exists(lp):
            print(f"check edit {i + 1} ({edits[i][0]}): NO LIVE PDF")
            ok = False
            continue
        same = filecmp.cmp(lp, rp, shallow=False)
        msg = "bytes equal" if same else ""
        if not same:
            a, b = pdf_text_positions(lp), pdf_text_positions(rp)
            msg = "bytes differ; text+positions " + ("equal" if a == b else "DIFFER")
            ok = ok and a == b
        if SYNCTEX:
            same_s = synctex_same(lp[:-4] + ".synctex.gz", live, f"{rd}/{stem}.synctex.gz", rd)
            msg += f"; synctex {'equal' if same_s else 'DIFFERS'}"
            ok = ok and same_s
        print(f"check edit {i + 1} ({edits[i][0]}): {msg} (stock {rruns} runs {rbibs} bibtex {ms:.0f} ms{live_runs})")
    if SYNCTEX and finals:  # bytes too: a stock run in the live directory itself (same paths) on the last state
        last = finals[seqs[-1]][-1][:-4] + ".synctex.gz"
        pdflatex("stock", live, main)
        same_b = filecmp.cmp(last, f"{live}/{stem}.synctex.gz", shallow=False)
        print(f"check synctex bytes, last edit, stock in the live dir: {'equal' if same_b else 'DIFFER'}")
        ok = ok and same_b
    print(f"{name}: {'CORRECT' if ok else 'MISMATCH'}")
    lat = sorted(float(l.split("\t")[8]) for l in r.stdout.splitlines()
                 if l.startswith("edit\t") and l.split("\t")[1].isdigit() and len(l.split("\t")) > 8
                 and l.split("\t")[2] != "preamble")
    if lat:
        q = lambda f: lat[min(int(f * len(lat)), len(lat) - 1)]
        print(f"{name}: edit-to-PDF without the preamble edit, n={len(lat)}: p50 {q(0.5):.1f} ms, p95 {q(0.95):.1f} ms, "
              f"max {lat[-1]:.1f} ms")
    for row in finals.values():
        if len(row) > 17 and int(row[14]) > 1:
            print(f"{name}: rerun {row[2]}: first PDF {float(row[8]):.1f} ms, {row[14]} runs, {row[15]} bibtex, "
                  f"converged {float(row[16]):.1f} ms")


def finish(name, main, extra):
    base = f"{WORK}/{name}/base"
    live = f"{WORK}/{name}/live-finish"
    out = f"{WORK}/{name}/out-finish"
    shutil.rmtree(live, ignore_errors=True)
    shutil.rmtree(out, ignore_errors=True)
    shutil.copytree(base, live)
    empty = f"{WORK}/{name}/none.edits"
    open(empty, "w").close()
    print(f"{name}: finish after every page, load {load()}")
    r = subprocess.run([DRIVER, "--engine", ENGINES["live"], "--finish-all", *extra, live, main, empty, out],
                       env=env("live"), capture_output=True, text=True)
    print(r.stdout)
    if r.stderr:
        print(r.stderr[-2000:])


def find_makeglossaries():
    """TeX Live's makeglossaries script, in the year's tree (kpathsea fetches it from the store)."""
    if not YEAR:
        return None
    kpse = f"{BUILD}/stock/texk/kpathsea/kpsewhich"
    r = subprocess.run([kpse, "-format=texmfscripts", "makeglossaries"], env=env("stock"), capture_output=True, text=True)
    p = r.stdout.strip()
    return p if p and os.path.exists(p) else None


if __name__ == "__main__":
    MAKEGLOSSARIES = find_makeglossaries() if MAKEINDEX else None
    a = sys.argv[1:]
    if a[:1] == ["fmt"]:
        fmt()
    elif a[:1] == ["run"] and len(a) >= 4:
        run(a[1], os.path.expanduser(a[2]), a[3], a[4:])
    elif a[:1] == ["finish"] and len(a) >= 3:
        finish(a[1], a[2], a[3:])
    else:
        sys.exit(__doc__ if __doc__ else "see the header of bench.py")
