// Runs inside the Overleaf CE container, from /overleaf/services/web/modules/server-ce-scripts/scripts/.
// Creates (or resets) test users with known passwords. Idempotent.
// Input: JSON on stdin, [{email, password, firstName, admin}]. Output: JSON [{email, id}] on stdout.
import { db } from '../../../app/src/infrastructure/mongodb.mjs'
import UserRegistrationHandler from '../../../app/src/Features/User/UserRegistrationHandler.mjs'
import UserGetter from '../../../app/src/Features/User/UserGetter.mjs'
import AuthenticationManager from '../../../app/src/Features/Authentication/AuthenticationManager.mjs'

async function readStdin() {
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  return JSON.parse(Buffer.concat(chunks).toString('utf8'))
}

const users = await readStdin()
const out = []
try {
  for (const u of users) {
    let user = await UserGetter.promises.getUserByAnyEmail(u.email)
    if (!user) {
      user = await UserRegistrationHandler.promises.registerNewUser({
        email: u.email,
        password: u.password,
        first_name: u.firstName,
        analyticsId: crypto.randomUUID(),
      })
    } else {
      await AuthenticationManager.promises._setUserPasswordInMongo(user, u.password)
    }
    await db.users.updateOne(
      { _id: user._id },
      { $set: { isAdmin: !!u.admin, first_name: u.firstName, emails: user.emails.map(e => ({ ...e, confirmedAt: e.confirmedAt || new Date() })) } }
    )
    out.push({ email: u.email, id: user._id.toString() })
  }
  console.log('TAUDOT_RESULT ' + JSON.stringify(out))
  process.exit(0)
} catch (error) {
  console.error(error)
  process.exit(1)
}
