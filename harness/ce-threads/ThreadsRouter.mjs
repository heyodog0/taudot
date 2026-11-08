// The routes the review panel calls, as docs/protocol.md lists them. Our own code against CE's internal APIs
// (ChatApiHandler, DocumentUpdaterHandler, EditorRealTimeController).
import { expressify } from '@overleaf/promise-utils'
import ChatApiHandler from '../../app/src/Features/Chat/ChatApiHandler.mjs'
import ChatManager from '../../app/src/Features/Chat/ChatManager.mjs'
import DocumentUpdaterHandler from '../../app/src/Features/DocumentUpdater/DocumentUpdaterHandler.mjs'
import EditorRealTimeController from '../../app/src/Features/Editor/EditorRealTimeController.mjs'
import SessionManager from '../../app/src/Features/Authentication/SessionManager.mjs'
import AuthenticationController from '../../app/src/Features/Authentication/AuthenticationController.mjs'
import AuthorizationMiddleware from '../../app/src/Features/Authorization/AuthorizationMiddleware.mjs'
import UserInfoManager from '../../app/src/Features/User/UserInfoManager.mjs'
import UserInfoController from '../../app/src/Features/User/UserInfoController.mjs'

const chat = ChatApiHandler.promises
const docUpdater = DocumentUpdaterHandler.promises
const emit = (projectId, event, ...args) => EditorRealTimeController.emitToRoom(projectId, event, ...args)
const me = req => SessionManager.getLoggedInUserId(req.session)

async function userInfo(userId) {
  return UserInfoController.formatPersonalInfo(await UserInfoManager.promises.getPersonalInfo(userId))
}

async function getThreads(req, res) {
  const threads = await chat.getThreads(req.params.project_id)
  res.json(await ChatManager.promises.injectUserInfoIntoThreads(threads))
}

async function sendMessage(req, res) {
  const { project_id: projectId, thread_id: threadId } = req.params
  const content = req.body?.content
  if (typeof content !== 'string' || content.length === 0) return res.sendStatus(400)
  const message = await chat.sendComment(projectId, threadId, me(req), content)
  message.user = await userInfo(message.user_id)
  emit(projectId, 'new-comment', threadId, message)
  res.sendStatus(204)
}

// Only the author edits or deletes their own message through these.
async function isAuthor(req, res, next) {
  const { project_id: projectId, thread_id: threadId, message_id: messageId } = req.params
  const m = await chat.getThreadMessage(projectId, threadId, messageId)
  if (m?.user_id === me(req)) return next()
  res.sendStatus(403)
}

async function editMessage(req, res) {
  const { project_id: projectId, thread_id: threadId, message_id: messageId } = req.params
  const content = req.body?.content
  if (typeof content !== 'string') return res.sendStatus(400)
  await chat.editMessage(projectId, threadId, messageId, me(req), content)
  emit(projectId, 'edit-message', threadId, messageId, content)
  res.sendStatus(204)
}

async function deleteMessage(req, res) {
  const { project_id: projectId, thread_id: threadId, message_id: messageId } = req.params
  await chat.deleteMessage(projectId, threadId, messageId)
  emit(projectId, 'delete-message', threadId, messageId)
  res.sendStatus(204)
}

async function deleteOwnMessage(req, res) {
  const { project_id: projectId, thread_id: threadId, message_id: messageId } = req.params
  await chat.deleteUserMessage(projectId, threadId, me(req), messageId)
  emit(projectId, 'delete-message', threadId, messageId)
  res.sendStatus(204)
}

async function resolveThread(req, res) {
  const { project_id: projectId, doc_id: docId, thread_id: threadId } = req.params
  const userId = me(req)
  await chat.resolveThread(projectId, threadId, userId)
  await docUpdater.resolveThread(projectId, docId, threadId, userId)
  emit(projectId, 'resolve-thread', threadId, await userInfo(userId))
  res.sendStatus(204)
}

async function reopenThread(req, res) {
  const { project_id: projectId, doc_id: docId, thread_id: threadId } = req.params
  await chat.reopenThread(projectId, threadId)
  await docUpdater.reopenThread(projectId, docId, threadId, me(req))
  emit(projectId, 'reopen-thread', threadId)
  res.sendStatus(204)
}

async function deleteThread(req, res) {
  const { project_id: projectId, doc_id: docId, thread_id: threadId } = req.params
  await docUpdater.deleteThread(projectId, docId, threadId, me(req))
  await chat.deleteThread(projectId, threadId)
  emit(projectId, 'delete-thread', threadId)
  res.sendStatus(204)
}

export default {
  apply(webRouter) {
    const login = AuthenticationController.requireLogin()
    const read = AuthorizationMiddleware.ensureUserCanReadProject
    const review = AuthorizationMiddleware.ensureUserCanWriteOrReviewProjectContent
    const admin = AuthorizationMiddleware.ensureUserCanAdminProject
    const resolve = AuthorizationMiddleware.ensureUserCanDeleteOrResolveThread
    const thread = '/project/:project_id/thread/:thread_id'
    const docThread = '/project/:project_id/doc/:doc_id/thread/:thread_id'
    webRouter.get('/project/:project_id/threads', login, read, expressify(getThreads))
    webRouter.post(`${thread}/messages`, login, review, expressify(sendMessage))
    webRouter.post(`${thread}/messages/:message_id/edit`, login, read, expressify(isAuthor), expressify(editMessage))
    webRouter.delete(`${thread}/messages/:message_id`, login, admin, expressify(deleteMessage))
    webRouter.delete(`${thread}/own-messages/:message_id`, login, read, expressify(isAuthor), expressify(deleteOwnMessage))
    webRouter.post(`${docThread}/resolve`, login, resolve, expressify(resolveThread))
    webRouter.post(`${docThread}/reopen`, login, resolve, expressify(reopenThread))
    webRouter.delete(docThread, login, resolve, expressify(deleteThread))
  },
}
