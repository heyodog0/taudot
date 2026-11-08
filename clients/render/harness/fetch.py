"""Fetch arXiv source tarballs into the corpus folder (outside the repo), politely: export.arxiv.org, one request at a
time, DELAY s apart, a User-Agent that names the project. Already fetched papers are skipped.

    uv run python fetch.py ID [ID...]
"""

import gzip
import io
import sys
import tarfile
import time
import urllib.request
from pathlib import Path

CORPUS = Path.home() / "code/lab/taudot-ref/corpus"
DELAY = 15.0
UA = "Taudot-renderer-harness/0.1 (fidelity corpus; one request at a time)"


def folder(arxiv_id: str) -> Path:
    return CORPUS / arxiv_id.replace("/", "_")


def fetch(arxiv_id: str) -> str:
    d = folder(arxiv_id)
    if (d / ".fetched").exists():
        return "cached"
    req = urllib.request.Request(f"https://export.arxiv.org/e-print/{arxiv_id}", headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    d.mkdir(parents=True, exist_ok=True)
    raw = gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data
    try:
        with tarfile.open(fileobj=io.BytesIO(raw)) as t:
            t.extractall(d, filter="data")
        kind = "tar"
    except tarfile.ReadError:
        if raw[:4] == b"%PDF":
            (d / "paper.pdf").write_bytes(raw)
            kind = "pdf only"
        else:
            (d / "main.tex").write_bytes(raw)
            kind = "single tex"
    (d / ".fetched").write_text(kind + "\n")
    return kind


if __name__ == "__main__":
    for a in sys.argv[1:]:
        for attempt in range(3):
            try:
                r = fetch(a)
                break
            except Exception as e:
                r = f"error {e}"
                if "429" in r or "IncompleteRead" in r:
                    time.sleep(120 * (attempt + 1))   # arXiv asks us to slow down
                else:
                    break
        print(a, r, flush=True)
        if r != "cached":
            time.sleep(DELAY)
