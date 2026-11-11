# bench: live typesetting, side by side

Taudot's live typesetting against rtex, liveTeX-Rosina, TeXpresso, Typst and stock latexmk: the same documents,
the same edits, one machine. Results and definitions: [docs/bench.md](../docs/bench.md).

```console
$ sh bench/build.sh                                  # everything from source, into ~/code/lab/taudot-ref/bench
$ uv run --with pypdf bench/gen.py                   # documents and the edit script (10/100/300 pp. + 3 arXiv papers)
$ uv run --no-project --with pypdf bench/run.py all  # every system on every document; rows into bench/results/
$ uv run --no-project bench/report.py                # tables into docs/bench.md, chart docs/bench.svg
```

One system on one document: `bench/run.py SYSTEM DOC ENGINE` (e.g. `rtex synth-100 lualatex`); latexmk runs first
on a document, since its output after each edit is the reference the others are checked against.

| File | |
|---|---|
| `gen.py` | the documents and `edits.json` (where the keys go) |
| `run.py` | one driver per system, the timing loop, the checks against stock |
| `report.py` | tables and chart |
| `common.py` | paths, TeX environment, page comparison, memory sampling |
| `build.sh` | the builds (shallow clones; build trees removed afterwards) |
| `results/edits.tsv` | one row per edit: times, preview state, exactness |
| `results/first.tsv` | one row per run: first compile, peak memory, load average |
| `results/opens.tsv` | first page on open (`run.py opens`): one row per open, with its load |
| `results/memory.tsv` | memory per phase (`run.py memory`, `BENCH_TAG` names the build): phys_footprint, RSS, processes |
| `results/burst.tsv`, `burst_runs.tsv` | the burst script (`run.py burst`): one row per key, one per run with its load |

Needs TeX Live 2026's store tree and the stock engines from `clients/universal/` (see its README). Other systems'
code is never copied here; the scripts drive their binaries.
