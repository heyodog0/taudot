# Re-login check against the local CE (run by hand; see the log entry of 2026-11-01):
#   H=$(mktemp -d)/h; mkdir -p $H
#   TAUDOT_LOG=info,overleaf=debug NO_COLOR=1 target/debug/taudot serve --env-file ~/code/lab/taudot/docker/.env.test \
#     --user user2 --home $H 2> $H.log &
#   uv run --no-project python crates/engine/tests/ce/relogin.py $H <throwaway project id> $H.log
# Deletes user2's (Bob's) sessions from Redis, disconnects the engine's socket through real-time's HTTP API, and
# checks that the engine logs in again and an edit is confirmed. Test users only.
import json, socket, subprocess, sys, time, os
home, project = sys.argv[1], sys.argv[2]
bob = [l.split('=',1)[1].strip() for l in open(os.path.expanduser('~/code/lab/taudot/docker/.env.test')) if l.startswith('OVERLEAF_USER2_ID=')][0]
s = socket.socket(socket.AF_UNIX); s.connect(home + '/engine.sock'); f = s.makefile('rw')
n = 0
def call(m, p):
    global n; n += 1
    f.write(json.dumps({"jsonrpc":"2.0","id":n,"method":m,"params":p})+"\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if r.get('id') == n: return r
print(call('project.open', {'project_id': project})['result']['me'])
d = call('doc.open', {'project_id': project, 'path': 'main.tex'})['result']
doc = d['doc_id']
call('activity.subscribe', {'project_id': project})
def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True).stdout
killed = 0
for k in sh("docker exec texsync-redis redis-cli --scan --pattern 'sess:*'").split():
    if bob in sh(f"docker exec texsync-redis redis-cli get '{k}'"):
        sh(f"docker exec texsync-redis redis-cli del '{k}'"); killed += 1
print('deleted bob sessions:', killed)
import re
sids = re.findall(r'sid=([A-Za-z0-9_-]+)', re.sub(r'\x1b\[[0-9;]*m', '', open(sys.argv[3]).read()))
for c in sids[-1:]:
        print('disconnect', c, sh(f"docker exec texsync-sharelatex curl -s -o /dev/null -w '%{{http_code}}' -X POST http://127.0.0.1:3026/client/{c}/disconnect"))
for _ in range(100):
    st = call('project.status', {'project_id': project})['result']
    if st['connection'] == 'online': break
    time.sleep(0.2)
time.sleep(1)
for _ in range(100):
    st = call('project.status', {'project_id': project})['result']
    if st['connection'] == 'online': break
    time.sleep(0.2)
print('connection', st['connection'])
r = call('doc.edit', {'doc_id': doc, 'seq': st['docs'][0]['seq'], 'edits': [{'pos': 0, 'del': 0, 'ins': '%relogin\n'}]})
print('edit', r)
for _ in range(100):
    st = call('project.status', {'project_id': project})['result']
    if st['docs'][0]['state'] == 'idle': break
    time.sleep(0.1)
print('state', st['docs'][0]['state'], 'v', st['docs'][0]['version'])
