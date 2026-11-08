# GPL-2.0-or-later. Reads files out of a TeX Live release ISO on an HTTP server, by byte ranges, without
# downloading it: an index of /archive/*.tar.xz and /tlpkg/ (name, offset, size), then one range request a file.
import os
import sys
import urllib.request

CHUNK = 1 << 18


class HTTPFile:
    """A read-only, seekable file over HTTP ranges, with a chunk cache (pycdlib reads many small records)."""

    def __init__(self, url):
        self.url, self.pos, self.cache = url, 0, {}
        req = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(req) as r:
            self.size = int(r.headers["Content-Length"])

    def range(self, start, n):
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={start}-{start + n - 1}"})
        with urllib.request.urlopen(req) as r:
            return r.read()

    def chunk(self, i):
        if i not in self.cache:
            self.cache[i] = self.range(i * CHUNK, min(CHUNK, self.size - i * CHUNK))
        return self.cache[i]

    def read(self, n=-1):
        if n < 0:
            n = self.size - self.pos
        out = bytearray()
        while n > 0 and self.pos < self.size:
            c = self.chunk(self.pos // CHUNK)
            o = self.pos % CHUNK
            b = c[o:o + n]
            out += b
            self.pos += len(b)
            n -= len(b)
        return bytes(out)

    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else self.pos + off if whence == 1 else self.size + off
        return self.pos

    def tell(self):
        return self.pos


def index(url, out):
    import pycdlib
    iso = pycdlib.PyCdlib()
    f = HTTPFile(url)
    iso.open_fp(f)
    rows = []
    for d in ("/archive", "/tlpkg"):
        for c in iso.list_children(rr_path=d):
            if c.is_dir() or c.is_dot() or c.is_dotdot():
                continue
            name = c.rock_ridge.name().decode()
            rows.append(f"{d[1:]}/{name}\t{c.extent_location() * 2048}\t{c.get_data_length()}\n")
    with open(out + ".part", "w") as o:
        o.writelines(sorted(rows))
    os.rename(out + ".part", out)
    print(f"{len(rows)} files indexed, {len(f.cache)} chunks read", file=sys.stderr)


if __name__ == "__main__":
    index(sys.argv[1], sys.argv[2])
