// Reads docker/.env.test, written by docker/up.sh and docker/seed.sh.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

export const ENV_FILE = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'docker', '.env.test')

export type TestUser = { email: string; password: string; id: string }

export type TestEnv = {
  url: string
  admin: TestUser
  users: TestUser[]
  projects: { classic?: string; historyOt?: string }
  raw: Record<string, string>
  /** The env file this was read from. */
  path: string
}

export function loadEnv(path: string = process.env.TAUDOT_ENV_FILE ?? ENV_FILE): TestEnv {
  const raw: Record<string, string> = {}
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/)
    if (m) raw[m[1]] = m[2]
  }
  const user = (prefix: string): TestUser => ({
    email: raw[`${prefix}_EMAIL`],
    password: raw[`${prefix}_PASSWORD`],
    id: raw[`${prefix}_ID`],
  })
  return {
    url: raw.OVERLEAF_URL ?? 'http://localhost:8800',
    admin: user('OVERLEAF_ADMIN'),
    users: [user('OVERLEAF_USER1'), user('OVERLEAF_USER2')],
    projects: { classic: raw.OVERLEAF_PROJECT_CLASSIC_ID, historyOt: raw.OVERLEAF_PROJECT_HISTORYOT_ID },
    raw,
    path,
  }
}

/** Resolve a user given as 1, 2, "admin" or an email. */
export function pickUser(env: TestEnv, who: string | undefined): TestUser {
  if (!who || who === '1') return env.users[0]
  if (who === '2') return env.users[1]
  if (who === 'admin') return env.admin
  const found = [env.admin, ...env.users].find(u => u.email === who)
  if (!found) throw new Error(`unknown user ${who}`)
  return found
}

/** Resolve a project given as "classic", "history-ot" or an ID. */
export function pickProject(env: TestEnv, project: string): string {
  if (project === 'classic') return need(env.projects.classic, 'classic')
  if (project === 'history-ot') return need(env.projects.historyOt, 'history-ot')
  return project
}

function need(id: string | undefined, name: string): string {
  if (!id) throw new Error(`no ${name} project in ${ENV_FILE}; run docker/seed.sh`)
  return id
}
