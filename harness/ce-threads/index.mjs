// taudot: comment-thread routes for our local Overleaf CE, which leaves them out (they ship in Server Pro and on
// overleaf.com). CE already has the chat service and the web-side helpers; this module only adds the browser's
// routes (docs/protocol.md, Comments) and the socket events that go with them. Installed by install.sh; for tests
// only, never for a real server.
import ThreadsRouter from './ThreadsRouter.mjs'

export default { router: ThreadsRouter }
