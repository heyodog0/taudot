# The TeX Live store

TeX Live files hosted by us, each stored once under its SHA-512, copied from TeX Live's Subversion repository at
each Overleaf image's revision. The client checks every byte against a hash it trusts, so the server only has to be
fast. Code: `tools/texstore/`.

## Layout

Base URL `https://texlive.taudot.app` (R2 bucket `taudot-texlive`, public read only; never `r2.dev`).

| key | content | caching |
|---|---|---|
| `files/<sha512>` | one file, gzipped. `<sha512>`: lowercase hex SHA-512 of the **uncompressed** bytes | `public, max-age=31536000, immutable` |
| `images/<name>/r<rev>` | one line: the SHA-512 of the image's index (in `files/`) | `max-age=300` |

`files/` holds TeX Live's files, generated files, package manifests and image indexes. Only `images/` keys change
(when generated files are rebuilt): a client pins its index hash and uses `images/` to discover a newer one. Objects
are `Content-Type: application/gzip` with **no** `Content-Encoding`, so no HTTP layer unpacks them.

### Images

An image is **`<name>@r<rev>`**: Overleaf's image name (`texlive-full:<name>`, e.g. `2026.1`) and the revision of
`svn://tug.org/texlive/trunk/Master` it holds. Each daily tlnet rebuild commits `tlpkg/texlive.tlpdb`, so a
mid-year image (on no ISO) is an svn revision, pinned by comparing Overleaf's logs with svn history
(`clients/pdftex/texlive/pin.py`).

### Compression

gzip (RFC 1952), level 9, no file name, mtime 0, so the same content always packs to the same bytes. On a 4,000-file
sample of TeX Live 2025 (packed / raw):

| | packed | decompress 4,000 files |
|---|---|---|
| gzip -9 | 0.576 | 86 ms |
| zstd -19 | 0.539 | 65 ms |
| xz -9e | 0.523 | 758 ms |

gzip is ~10% bigger than xz, but every client reads it with nothing added (TeX Live's zlib, Apple's Compression,
Python, `DecompressionStream`).

## The image index

`files/<hash>`, gzipped UTF-8, tab-separated, one record per line:

```
texstore  1
image     2026.1  r79468
svn       svn://tug.org/texlive/trunk/Master  79468  <sha512 of texlive.tlpdb at that revision>
P         <package>  <manifest sha512>  <files>  <bytes>  <package revision>
...
F         <path>  <size>  <package>
...
```

- `P` rows, sorted by name: every package with run files (no platform binaries, not `00texlive.*`), plus the
  pseudo-package `_generated` (empty revision).
- `F` rows, sorted by path (byte order): every run file of `scheme-full` plus the generated files. `<path>` is
  relative to `TEXMFROOT`, e.g. `texmf-dist/tex/latex/geometry/geometry.sty`.
- Unknown record types are skipped.

Per-file hashes are in the manifests: 180,000 SHA-512s would make the index several times bigger, and a compile
touches ~60 manifests.

## Package manifests

`files/<manifest sha512>`, gzipped, one line per file, sorted by path:

```
<path>  <size>  <sha512>  <x>
```

`<x>` is `x` for executables (scripts), else empty. A link inside a container is listed as its target.

## Generated files (`_generated`)

What a TeX Live installer makes locally, made once per image by us:

| path | what |
|---|---|
| `texmf-dist/ls-R`, `texmf-var/ls-R` | kpathsea's file lists, of the full install (generated files included) |
| `texmf-var/fonts/map/pdftex/updmap/pdftex.map` | `updmap` over every font package |
| `texmf-var/web2c/pdftex/pdflatex.fmt` | the image's pdfTeX with `fmtutil.cnf`'s command line |
| `texmf-dist/web2c/fmtutil.cnf`, `updmap.cfg`, `texmf-var/tex/generic/config/language.*` | TeX Live's `TLUtils.pm` |

A format loads only in the engine that dumped it, so it is tied to the engine build named in the log.

## How a client resolves a path

1. **Index.** Take the index hash (pinned, else `images/<name>/r<rev>`, asked once). Fetch `files/<hash>`, gunzip,
   check its SHA-512, keep it.
2. **Owner.** Binary-search the path's `F` row for its package. No row: not in TeX Live; stop without network.
3. **Manifest.** Fetch and check the package's manifest once per package: size and SHA-512 of the file.
4. **File.** Use the local cache's `<sha512>` if present; else fetch `files/<sha512>`, gunzip, check size and hash,
   cache it, and write it into the tree atomically (write beside, `rename`). The cache is keyed by hash, shared by
   all images.
5. **Fallback** (network error, non-200, wrong hash): `svn cat -r <rev> <svn URL>/<path>@<rev>`, checked against
   the manifest (the one exact public source). The index, manifests and generated files come only from the store or
   the cache: to survive an outage, keep the index in the app (1.5 MB packed for 2026) and pull all 4,574 manifests
   (15.0 MB) once in the background.

A hostile server can make a fetch fail, never return wrong bytes, as long as the index hash came from the client.

## Building and uploading

```sh
B="uv run --no-project python -I tools/texstore/build.py"
$B tlpdb 2026.1@r79468      # texlive.tlpdb at the revision
$B files 2026.1@r79468      # every run file: big directories by svn export, the rest by svn cat (resumes)
uv run --no-project python -I tools/texstore/gen.py 2026.1@r79468 ENGINE_BUILD   # generated files
$B index 2026.1@r79468      # ls-R, manifests, the image index, images/2026.1/r79468
$B stats                    # sizes and sharing
uv run --no-project python -I tools/texstore/serve.py           # the store over HTTP (stand-in for R2)
tools/texstore/tl-fetch PATH                                    # reference client, as kpathsea's fetch hook
tools/texstore/check-run.sh ...                                 # a pdfLaTeX run fetching only from the store
uv run --no-project --with boto3 python -I tools/texstore/upload.py   # new objects only, to R2
```

The store is built in `$TAUDOT_REF/texstore/store` (`TEXSTORE_REF`).

## Versions

The index's `texstore` line is the format version (1). A change a version-1 client can't read gets a new number;
adding record types doesn't.
