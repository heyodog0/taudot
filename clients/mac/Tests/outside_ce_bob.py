# Bob's engine: one doc.edit with several hunks (UTF-8 byte offsets, non-ASCII text), as another machine's engine
# sends a Claude session's save.   uv run --no-project python outside_ce_bob.py SOCKET PROJECT_ID PATH 'OLD=>NEW' ...
import json, socket, sys

sock, pid, path, *subs = sys.argv[1:]
s = socket.socket(socket.AF_UNIX); s.connect(sock)
f = s.makefile("rwb")
n = 0
def call(m, p):
    global n
    n += 1
    f.write((json.dumps({"jsonrpc": "2.0", "id": n, "method": m, "params": p}) + "\n").encode()); f.flush()
    while True:
        r = json.loads(f.readline())
        if r.get("id") == n:
            if "error" in r: sys.exit(f"{m}: {r['error']}")
            return r["result"]
call("project.open", {"project_id": pid})
d = call("doc.open", {"project_id": pid, "path": path})
text = d["text"].encode()
edits = []
for sub in subs:  # each OLD=>NEW against the text so far, in order (positions after the earlier hunks)
    a, b = (x.encode() for x in sub.split("=>"))
    assert text.count(a) == 1, (a, text.count(a))
    pos = text.index(a)
    edits.append({"pos": pos, "del": len(a), "ins": b.decode()})
    text = text[:pos] + b + text[pos + len(a):]
r = call("doc.edit", {"doc_id": d["doc_id"], "seq": d["seq"], "edits": edits})
print("bob:", len(edits), "hunks, seq", r.get("seq"))
