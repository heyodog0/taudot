#!/usr/bin/env node
// Session expiry (round 1 open question 5). The session lives in redis as sess:<id> with a rolling TTL: web requests
// reset it, socket traffic does not. A long-running engine must make a cheap web request now and then.
import { execFileSync } from 'node:child_process'
import { Check, env, joined, project, sleep } from './common.ts'
import { login, RealtimeClient } from '../lib/socket.ts'

const check = new Check('session')
const pid = project('protocol classic')
const cookie = await login(env.url, env.users[0])
const m = cookie.match(/overleaf\.sid=s%3A([^.;]+)/)
if (!m) throw new Error(`unexpected cookie ${cookie}`)
const ttl = () => Number(execFileSync('docker', ['exec', 'texsync-redis', 'redis-cli', 'TTL', `sess:${m[1]}`], { encoding: 'utf8' }).trim())
check.note('cookieName', cookie.split('=')[0])
const t0 = ttl()
check.note('ttlAfterLogin', t0)
check.that(t0 > 432000 - 60 && t0 <= 432000, 'TTL is 5 days after login')

const c = new RealtimeClient(env.url, cookie)
await c.connect(pid)
const j = await joined(c, 'main.tex')
await sleep(3000)
for (let k = 0; k < 5; k++) {
  await c.emit('clientTracking.getConnectedUsers')
  await c.joinDoc(j.docId)
  await sleep(1000)
}
const t1 = ttl()
check.note('ttlAfterSocketTraffic', t1)
check.that(t1 <= t0 - 7, 'socket traffic does not reset the TTL')
await fetch(`${env.url}/user/settings`, { headers: { cookie } })
const t2 = ttl()
check.note('ttlAfterWebRequest', t2)
check.that(t2 > t1 + 5, 'a web request resets the TTL')
c.close()
check.done()
