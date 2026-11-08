# /// script
# requires-python = ">=3.11"
# ///
"""Which paragraphs one build proves and another doesn't (matched by their first line's text).

uv run tests/diffbuilds.py OLD_BINARY NEW_BINARY FILE.pdf
"""
import os, re, subprocess, sys, tempfile

def run(binary, pdf):
    lines = subprocess.run([binary, "lines", pdf], capture_output=True, text=True).stdout.splitlines()
    first = {}
    for i, l in enumerate(lines):
        m = re.match(r"¶(\d+) ", l)
        if m and i + 1 < len(lines):
            first[int(m.group(1))] = lines[i + 1].split("| ", 1)[-1][:50]
    with tempfile.TemporaryDirectory() as w:
        out = subprocess.run([binary, "prove", pdf], capture_output=True, text=True, env={**os.environ, "PDFSOURCE_WORK": w}).stdout
    verdict = {}
    for l in out.splitlines():
        m = re.match(r"¶(\d+) (PROVEN|no) .*?(?:max_dx=\S+ )?(.*)$", l)
        if m:
            verdict[first.get(int(m.group(1)), "?")] = (m.group(2) == "PROVEN", m.group(3))
    return verdict

old, new = run(sys.argv[1], sys.argv[3]), run(sys.argv[2], sys.argv[3])
for k, (p, _) in old.items():
    if p and not new.get(k, (False, "missing"))[0]:
        print(f"lost: {k!r}: {new.get(k, (False, 'not a paragraph now'))[1]}")
for k, (p, _) in new.items():
    if p and not old.get(k, (False, ""))[0]:
        print(f"gained: {k!r}")
