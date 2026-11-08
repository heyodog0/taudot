# GPL-2.0-or-later. Finds the TeX Live update (a day of tlnet) that matches an Overleaf TeX Live image.
#
#   uv run --no-project python clients/pdftex/texlive/pin.py YEAR VERSIONS FROM TO
#   uv run --no-project python clients/pdftex/texlive/pin.py probe FROM TO OUT.tex    a probe document (below)
#   uv run --no-project python clients/pdftex/texlive/pin.py versions LOG > VERSIONS  VERSIONS from a probe's log
#
# VERSIONS: one `name date version` per line, from the `Package:`/`File:`/`Document Class:` lines of an Overleaf
# output.log (names as the log gives them: `hyperref`, `size10.clo`, `pgfcore.code.tex`). Keep it out of the repo,
# and leave out files the project ships itself (a project's own natbib.sty shadows TeX Live's).
#
# Source: TeX Live's Subversion repository (svn://tug.org/texlive, its public access; needs an `svn` client).
# tlnet is rebuilt from it once a day, and each rebuild commits Master/tlpkg/texlive.tlpdb, so those commits are
# the days of tlnet. For every listed file: its changes between FROM and TO (svn log) and its header date at each
# (svn cat). Then for each daily update: a file newer than the log's means the image is older than that day; older
# means newer. Prints the range of updates where every file matches.
# The probe: a document that opens every .sty/.cls/.def/.cfg/.clo/.fd/.tex file svn changed between FROM and TO,
# reads its first 80 lines as strings (nothing is executed), and writes the lines that carry its date to the log,
# with `PROBE name` before them. Compiled on a throwaway Overleaf project on the image to pin, its log narrows the
# image to the days where all those files match. Missing files are logged as `PROBE-MISSING name`.
import concurrent.futures as cf
import os
import re
import subprocess
import sys

REPO = "svn://tug.org/texlive/trunk/Master"
DATE = re.compile(r"(\d{4})[-/](\d\d)[-/](\d\d)")


def svn(*args):
    for _ in range(3):
        r = subprocess.run(["svn", *args], capture_output=True, text=True, errors="replace")
        if r.returncode == 0:
            return r.stdout
    return None


def header_dates(text):
    """Dates in the file's \\Provides... / FileDate lines (its version stamp)."""
    out = set()
    lines = text.splitlines()[:300]
    for i, line in enumerate(lines):
        if re.search(r"Provides|FileDate|filedate|ExplFileDate|\\def\\fileversion|\\def\\filedate", line):
            for l in lines[i:i + 3]:  # the [date version] often follows on the next line
                out.update("-".join(m) for m in DATE.findall(l))
    return out


def log_revs(path, lo, hi):
    """[(rev, date)] of commits touching path between lo and hi (svn date specs)."""
    out = svn("log", "-q", "-r", f"{{{lo}}}:{{{hi}}}", f"{REPO}/{path}") or ""
    return [(int(m.group(1)), m.group(2)) for m in re.finditer(r"^r(\d+) \| \S+ \| (\S+ \S+)", out, re.M)]


def main(year, versions, lo, hi):
    want = {}
    for line in open(versions):
        w = line.split()
        if len(w) >= 2 and DATE.match(w[1]):
            want[w[0]] = "-".join(DATE.match(w[1]).groups())
    # file names -> svn paths, from the package database at FROM
    db = svn("cat", "-r", f"{{{lo}}}", f"{REPO}/tlpkg/texlive.tlpdb") or sys.exit("no tlpdb at FROM")
    by_base = {}
    for line in db.splitlines():
        if line.startswith(" texmf-dist/") or line.startswith(" RELOC/"):  # the repository's tlpdb isn't relocated
            p = line[1:].split(" ", 1)[0].replace("RELOC/", "texmf-dist/")
            by_base.setdefault(os.path.basename(p), p)
    paths = {}
    for n in want:
        for cand in (n, n + ".sty", n + ".cls", n + ".tex"):
            if cand in by_base:
                paths[n] = by_base[cand]
                break
    print(f"{len(paths)} of {len(want)} log files found in TeX Live", file=sys.stderr)
    updates = log_revs("tlpkg/texlive.tlpdb", lo, hi)  # the days of tlnet
    print(f"{len(updates)} tlnet updates between {lo} and {hi}", file=sys.stderr)

    def history(n):
        """[(rev, verdict)] for file n: verdict at FROM, then at each change."""
        p = paths[n]
        base = svn("cat", "-r", f"{{{lo}}}", f"{REPO}/{p}")
        hist = [(0, base)]
        for rev, _ in log_revs(p, lo, hi):
            hist.append((rev, svn("cat", "-r", str(rev), f"{REPO}/{p}")))
        out = []
        for rev, text in hist:
            ds = header_dates(text or "")
            v = None if not ds else 0 if want[n] in ds else (1 if max(ds) > want[n] else -1)
            out.append((rev, v))
        return n, out

    with cf.ThreadPoolExecutor(8) as ex:
        hists = dict(ex.map(history, paths))
    checked = [n for n, h in hists.items() if any(v is not None for _, v in h)]
    rows = []
    for rev, date in updates:
        diffs = []
        for n in checked:
            v = [x for r, x in hists[n] if r <= rev][-1]
            if v:
                diffs.append((n, v))
        verdict = 1 if any(v > 0 for _, v in diffs) else -1 if diffs else 0
        rows.append((rev, date, verdict, diffs))
    match = [r for r in rows if r[2] == 0]
    # the boundary updates, for the log
    for i, (rev, date, v, diffs) in enumerate(rows):
        nxt = rows[i + 1][2] if i + 1 < len(rows) else None
        prv = rows[i - 1][2] if i else None
        if v == 0 or nxt == 0 or prv == 0:
            print(f"r{rev} {date}: {('too early', 'match', 'too late')[v + 1]} "
                  f"{' '.join(f'{n}{chr(43) if c > 0 else chr(45)}' for n, c in diffs[:8])}", file=sys.stderr)
    if not match:
        early = [r for r in rows if r[2] < 0]
        late = [r for r in rows if r[2] > 0]
        print(f"no update matches all {len(checked)} files; last too early: "
              f"{early[-1][:2] if early else None}, first too late: {late[0][:2] if late else None}")
        if early:
            print("still older at the last too-early update:", " ".join(n for n, c in early[-1][3] if c < 0))
        if late:
            print("newer at the first too-late update:", " ".join(n for n, c in late[0][3] if c > 0))
        return 1
    print(f"Overleaf image {year} = tlnet {match[0][1][:10]} .. {match[-1][1][:10]} "
          f"(svn r{match[0][0]}..r{match[-1][0]}, {len(match)} daily updates; all {len(checked)} dated files match)")
    return 0


PROBE_EXT = (".sty", ".cls", ".def", ".cfg", ".clo", ".fd", ".tex")


def probe(lo, hi, out):
    """Write the probe document for the files svn changed between lo and hi (dates)."""
    log = svn("log", "-q", "-v", "-r", f"{{{lo}}}:{{{hi}}}", f"{REPO}/texmf-dist") or ""
    names = {}
    for m in re.finditer(r"^   [AM] /trunk/Master/(texmf-dist/(?:tex)/\S+)$", log, re.M):
        p = m.group(1)
        b = os.path.basename(p)
        if b.endswith(PROBE_EXT) and re.fullmatch(r"[A-Za-z0-9._-]+", b):
            names.setdefault(b, p)
    body = "\n".join(f"\\probe{{{b}}}" for b in sorted(names))
    with open(out, "w") as f:
        f.write(r"""% Probe: the dated header lines of TeX Live files (generated by pin.py; nothing is executed)
\documentclass{article}
\ExplSyntaxOn
\ior_new:N \g__probe_ior
\int_new:N \l__probe_n_int
\int_new:N \l__probe_more_int
\str_new:N \l__probe_line_str
\cs_new_protected:Npn \probe #1
  {
    \file_if_exist:nTF {#1}
      {
        \iow_log:n { PROBE~#1 }
        \ior_open:Nn \g__probe_ior {#1}
        \int_zero:N \l__probe_n_int
        \int_zero:N \l__probe_more_int
        \bool_until_do:nn { \ior_if_eof_p:N \g__probe_ior || \int_compare_p:n { \l__probe_n_int > 80 } }
          {
            \ior_str_get:NN \g__probe_ior \l__probe_line_str
            \int_incr:N \l__probe_n_int
            \bool_set_false:N \l_tmpa_bool
            \clist_map_inline:nn { Provides, FileDate, filedate, fileversion }
              { \str_if_in:NnT \l__probe_line_str {##1} { \bool_set_true:N \l_tmpa_bool } }
            \bool_if:NT \l_tmpa_bool { \int_set:Nn \l__probe_more_int { 3 } }
            \int_compare:nT { \l__probe_more_int > 0 }
              {
                \iow_log:x { PROBE-LINE~\l__probe_line_str }
                \int_decr:N \l__probe_more_int
              }
          }
        \ior_close:N \g__probe_ior
      }
      { \iow_log:n { PROBE-MISSING~#1 } }
  }
\ExplSyntaxOff
\begin{document}
""" + body + "\nprobe done\n\\end{document}\n")
    print(f"{out}: {len(names)} files changed in svn between {lo} and {hi}", file=sys.stderr)


def versions(logfile):
    """`name date` per probed file, from a probe's log (the latest header date), as main() reads them."""
    cur, dates = None, {}
    text = open(logfile, encoding="utf-8", errors="replace").read()
    text = re.sub(r"\n(?!PROBE)", "", text)  # TeX wraps long log lines at 79 columns
    for line in text.splitlines():
        if line.startswith("PROBE-LINE "):
            if cur:
                dates.setdefault(cur, set()).update("-".join(m) for m in DATE.findall(line))
        elif line.startswith("PROBE "):
            cur = line[6:].strip()
        elif line.startswith("PROBE-MISSING "):
            cur = None
            print(f"# missing {line[14:].strip()}")
    for n, ds in sorted(dates.items()):
        if ds:
            print(f"{n} {max(ds)}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["probe"] and len(a) == 4:
        sys.exit(probe(*a[1:]))
    if a[:1] == ["versions"] and len(a) == 2:
        sys.exit(versions(a[1]))
    if len(a) != 4:
        sys.exit("usage: pin.py YEAR VERSIONS FROM TO")
    sys.exit(main(*a))
