# The TeX Live store

TeX Live files hosted by us, each stored once under its SHA-512. Each Overleaf TeX Live image is a frozen install
of TeX Live as it was at one point, so each image is copied once, file by file from TeX Live's Subversion repository
at that point, into storage we control. The client checks every byte against a hash it
already trusts, so the server only has to be fast, not trusted.

Code: `tools/texstore/`.

## Layout

All URLs are relative to the store's base URL, `https://texlive.taudot.app` (R2 bucket `taudot-texlive`, public read only; never `r2.dev`). Two kinds of key:

| key | content | caching |
|---|---|---|
| `files/<sha512>` | one file's bytes, gzipped. `<sha512>` is the lowercase hex SHA-512 of the **uncompressed** bytes. | immutable: `Cache-Control: public, max-age=31536000, immutable` |
| `images/<name>/r<rev>` | one line: the SHA-512 of that image's index (itself in `files/`) | short: `max-age=300` |

Everything is in `files/`: TeX Live's files, the generated files (format, `pdftex.map`, `ls-R`), each package's
manifest and each image's index. A file that is the same in several images is stored once. `images/` keys are the
only ones that may change (if an image's generated files are rebuilt); a client should pin the index hash it was
built with and use `images/` only to discover a newer one.

### Images

An image is **`<name>@r<rev>`**: Overleaf's image name (`texlive-full:<name>`, e.g. `2026.1`) and the revision of
TeX Live's svn (`svn://tug.org/texlive/trunk/Master`, its public access) whose files it holds. tlnet is rebuilt from
svn once a day and each rebuild commits `tlpkg/texlive.tlpdb`, so a tlnet day is an svn revision; a mid-year image
is on no ISO, but it is in svn. The revision is pinned per image by comparing Overleaf's logs with svn history
(the pdftex agent's `clients/pdftex/texlive/pin.py`). Rebuilding an image at another revision adds only the files
that differ.

Objects are served as `Content-Type: application/gzip` with **no** `Content-Encoding`, so no HTTP layer unpacks or
re-encodes them: the client always gets the stored gzip bytes and unpacks them itself.

### Compression

gzip (RFC 1952), level 9, no file name, mtime 0: the same content always packs to the same bytes. Chosen over xz
and zstd on a 4,000-file sample of TeX Live 2025 (fonts, `.sty`, `.tex`, `.tfm`, packed size / raw):

| | packed | decompress 4,000 files |
|---|---|---|
| gzip -9 | 0.576 | 86 ms |
| zstd -19 | 0.539 | 65 ms |
| xz -9e | 0.523 | 758 ms |

gzip costs ~10% more bytes than xz, but every client can read it with nothing added: zlib is in TeX Live's source
tree (so kpathsea can link it), Apple's Compression framework, Python's standard library and browsers'
`DecompressionStream`. Neither xz nor zstd is in all four.

## The image index

`files/<images/NAME/DATE>`, gzipped UTF-8 text, tab-separated, one record per line:

```
texstore  1
image     2026.1  r79468
svn       svn://tug.org/texlive/trunk/Master  79468  <sha512 of texlive.tlpdb at that revision>
P         <package>  <manifest sha512>  <files>  <bytes>  <package revision>
...
F         <path>  <size>  <package>
...
```

- `P` rows, sorted by package name: every TeX Live package with run files (no platform binaries, not the
  installer's `00texlive.*`), plus the pseudo-package `_generated`. The package revision is the tlpdb's (empty for
  `_generated`).
- `F` rows, sorted by path (byte order): every file of a full install (`scheme-full`, run files only), plus the
  generated files. `<path>` is relative to the install's root (`TEXMFROOT`), e.g. `texmf-dist/tex/latex/geometry/geometry.sty`.
- Unknown record types are skipped, so later versions can add some.

The per-file hashes are in the package manifests, not in the index: 180,000 SHA-512s don't compress, so inline
they would make the index several times bigger (sizes in the log), while a compile touches only ~60 manifests.

## Package manifests

`files/<manifest sha512>`, gzipped text, one line per file of the package, sorted by path:

```
<path>  <size>  <sha512>  <x>
```

`<x>` is `x` if the file is executable in TeX Live (scripts), else empty. A symbolic or hard link inside a
container is listed as the file it points to.

## Generated files (`_generated`)

Files a TeX Live installer makes on the user's machine, made once per image by us:

| path | what |
|---|---|
| `texmf-dist/ls-R`, `texmf-var/ls-R` | kpathsea's file lists, of every file of the full install (generated ones included) |
| `texmf-var/fonts/map/pdftex/updmap/pdftex.map` | from `updmap` over every font package |
| `texmf-var/web2c/pdftex/pdflatex.fmt` | built by the image's pdfTeX with `fmtutil.cnf`'s command line |
| `texmf-dist/web2c/fmtutil.cnf`, `updmap.cfg`, `texmf-var/tex/generic/config/language.*` | from TeX Live's `TLUtils.pm` |

A format only loads in the engine that dumped it, so the format is tied to the engine build named in the log.

## How a client resolves a path

1. **Index.** Take the image's index hash (pinned in the client, else `images/<name>/r<rev>`, asked once and kept). Fetch `files/<hash>`, gunzip,
   check its SHA-512. Keep it (it never changes).
2. **Owner.** Find the path's `F` row: its package (a binary search: the rows are sorted). No row: the file is not in
   TeX Live; stop without any network access.
3. **Manifest.** Fetch and check the package's manifest (`P` row) the same way, once per package; it gives the
   file's size and SHA-512.
4. **File.** If the local cache has `<sha512>`, use it. Otherwise fetch `files/<sha512>`, gunzip, check size and
   SHA-512, add it to the cache, and write it into the tree atomically (write beside, then `rename`).
   The cache is keyed by hash, so it is shared by every image.
5. **Fallback** when the store fails for a file (network error, non-200, wrong hash): the file from svn at the
   image's revision (`svn cat -r <rev> <svn URL>/<path>@<rev>`), checked against the manifest's SHA-512.
   (tlnet's daily archive on texlive.info is behind a bot check, and the release ISOs don't hold mid-year images, so
   svn is the one exact public source.)
   - The fallback needs the **metadata**: the index and the package's manifest. Those are ours (generated), so
     they come only from the store or the local cache, as do the generated files.
   - A client that must survive a store outage keeps the index (1.5 MB packed for 2026) in the app and pulls every
     manifest once in the background (4,574 manifests, 15.0 MB packed for 2026). Otherwise the fallback covers
     only packages already used once.

Only hashes decide what is accepted. A bad or hostile server can make a fetch fail, never make it return wrong bytes,
as long as the index hash came from the client itself.

A client may fetch a package's other files in parallel once it has the manifest; the store doesn't require it.

## Building and uploading

```sh
B="uv run --no-project python -I tools/texstore/build.py"
$B tlpdb 2026.1@r79468      # texlive.tlpdb at the revision
$B files 2026.1@r79468      # every run file: big directories by one svn export each, the rest by svn cat (resumes)
uv run --no-project python -I tools/texstore/gen.py 2026.1@r79468 ENGINE_BUILD   # generated files, by the image's pdfTeX
$B index 2026.1@r79468      # ls-R, manifests, the image index, images/2026.1/r79468
$B stats                    # sizes and sharing
uv run --no-project python -I tools/texstore/serve.py           # the store over HTTP (stand-in for R2)
tools/texstore/tl-fetch PATH                                    # reference client, as kpathsea's fetch hook
tools/texstore/check-run.sh ...                                 # a pdfLaTeX run fetching only from the store
uv run --no-project --with boto3 python -I tools/texstore/upload.py   # new objects only, to R2
```

The store is built in `~/code/lab/taudot-ref/texstore/store` (`TEXSTORE_REF`).

## Versions

The `texstore` line of the index gives the format version (1). A change a version-1 client can't read gets a new
number; adding record types doesn't.
