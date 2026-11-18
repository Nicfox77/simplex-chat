package chat.simplex.app

import chat.simplex.common.model.*
import chat.simplex.common.platform.chatSendCmdRetry
import chat.simplex.common.platform.ntfManager
import chat.simplex.common.platform.NotificationAction
import chat.simplex.common.views.call.*
import chat.simplex.common.views.helpers.AlertManager
import kotlinx.coroutines.*
import kotlinx.datetime.Clock
import java.io.Closeable
import kotlin.test.*

class LinkedCallTest {
  private val oldCtrl = ChatController.getChatCtrl()
  private val oldSend = chatSendCmdRetry
  private val oldUser = ChatModel.currentUser.value
  private val oldHost = ChatModel.currentRemoteHost.value
  private val oldCall = ChatModel.activeCall.value
  private val oldCommands = ChatModel.callCommand.toList()
  private val oldInvitations = ChatModel.callInvitations.toMap()
  private val oldActiveInvitation = ChatModel.activeCallInvitation.value
  private val oldSwitching = ChatModel.switchingCall.value
  private val oldShowCall = ChatModel.showCallView.value
  private val oldNotifications = runCatching { ntfManager }.getOrNull()
  private val sent = mutableListOf<String>()
  private var closed = false
  private var callNotifications = 0
  private var cancelledNotifications = 0
  private val user = User.sampleData
  private val contact = Contact.sampleData
  private val userRef = UserRef(user.userId, user.localDisplayName, true, true)

  @BeforeTest
  fun setUp() {
    ChatController.setChatCtrl(1L)
    ChatModel.currentUser.value = null
    ChatModel.currentRemoteHost.value = null
    ChatModel.activeCall.value = null
    ChatModel.callInvitations.clear()
    ChatModel.activeCallInvitation.value = null
    ChatModel.switchingCall.value = false
    ChatModel.callCommand.clear()
    ntfManager = object : chat.simplex.common.platform.NtfManager() {
      override fun notifyCallInvitation(invitation: RcvCallInvitation): Boolean { callNotifications++; return true }
      override fun cancelCallNotification() { cancelledNotifications++ }
      override fun displayNotification(user: UserLike, chatId: String, displayName: String, msgText: String, image: String?, actions: List<Pair<NotificationAction, () -> Unit>>) {}
      override fun hasNotificationsForChat(chatId: String) = false
      override fun cancelNotificationsForChat(chatId: String) {}
      override fun cancelNotificationsForUser(userId: Long) {}
      override fun cancelAllNotifications() {}
      override fun showMessage(title: String, text: String) {}
      override fun androidCreateNtfChannelsMaybeShowAlert() {}
    }
    chatSendCmdRetry = { _, cmd, _ ->
      sent += cmd
      """{"result":{"type":"cmdOk","user":null}}"""
    }
  }

  @AfterTest
  fun restore() {
    chatSendCmdRetry = oldSend
    ChatController.setChatCtrl(oldCtrl)
    ChatModel.currentUser.value = oldUser
    ChatModel.currentRemoteHost.value = oldHost
    ChatModel.activeCall.value = oldCall
    ChatModel.callInvitations.clear()
    ChatModel.callInvitations.putAll(oldInvitations)
    ChatModel.activeCallInvitation.value = oldActiveInvitation
    ChatModel.switchingCall.value = oldSwitching
    ChatModel.showCallView.value = oldShowCall
    oldNotifications?.let { ntfManager = it }
    ChatModel.callCommand.clear()
    ChatModel.callCommand.addAll(oldCommands)
    AlertManager.shared.hideAlert()
  }

  private fun call(host: Long?) = Call(
    remoteHostId = host, userProfile = user.profile.toProfile(), contact = contact,
    callUUID = "test-call", callState = CallState.InvitationSent,
    initialCallType = CallMediaType.Audio, androidCallState = Closeable { closed = true }
  )

  @Test
  fun signallingFromAnotherHostCannotModifyTheCall() = runBlocking {
    val call = call(1)
    ChatModel.activeCall.value = call
    for (event in listOf(
      CR.CallAnswer(userRef, contact, WebRTCSession("answer", "[]")),
      CR.CallExtraInfo(userRef, contact, WebRTCExtraInfo(null, "ice")),
      CR.CallEnded(userRef, contact)
    )) ChatController.processReceivedMsg(API.Result(2, event))
    assertSame(call, ChatModel.activeCall.value)
    assertTrue(ChatModel.callCommand.isEmpty())
    assertFalse(closed)
    assertTrue(sent.isEmpty())
  }

  @Test
  fun signallingFromTheOwningHostReachesWebRTC() = runBlocking {
    ChatModel.activeCall.value = call(1)
    ChatController.processReceivedMsg(API.Result(1, CR.CallAnswer(userRef, contact, WebRTCSession("answer", "[]"))))
    assertEquals(CallState.AnswerReceived, ChatModel.activeCall.value?.callState)
    assertTrue(ChatModel.callCommand.single() is WCallCommand.Answer)
  }

  @Test
  fun terminalEventClosesMediaWithoutSendingAHangupBack() = runBlocking {
    ChatModel.activeCall.value = call(1)
    ChatController.processReceivedMsg(API.Result(1, CR.CallEnded(userRef, contact)))
    withTimeout(3000) { while (ChatModel.activeCall.value != null) delay(10) }
    assertTrue(closed)
    assertTrue(sent.isEmpty())
  }

  @Test
  fun losingAnAnswerClaimNeverStartsMedia() = runBlocking {
    chatSendCmdRetry = { _, cmd, _ ->
      sent += cmd
      """{"error":{"type":"error","errorType":{"type":"hasCurrentCall"}}}"""
    }
    val invitation = RcvCallInvitation(null, user, contact, CallType(CallMediaType.Audio, CallCapabilities(true)), callUUID = "test", callTs = Clock.System.now())
    ChatModel.callManager.acceptIncomingCall(invitation).join()
    assertTrue(sent.any { it == "/_call claim @${contact.apiId} test" })
    assertNull(ChatModel.activeCall.value)
    assertTrue(ChatModel.callCommand.isEmpty())
  }

  private fun invitation(host: Long? = null) = RcvCallInvitation(host, user, contact, CallType(CallMediaType.Audio, CallCapabilities(true)), callUUID = "test", callTs = Clock.System.now())

  @Test
  fun answeringClaimsTheInvitationBeforeStartingWebRTC() = runBlocking {
    chatSendCmdRetry = { _, cmd, _ ->
      sent += cmd
      assertTrue(ChatModel.callCommand.isEmpty())
      assertNull(ChatModel.activeCall.value)
      """{"result":{"type":"cmdOk","user":null}}"""
    }
    ChatModel.callManager.acceptIncomingCall(invitation()).join()
    assertTrue(sent.last() == "/_call claim @${contact.apiId} test")
    assertEquals(CallState.InvitationAccepted, ChatModel.activeCall.value?.callState)
    assertTrue(ChatModel.callCommand.single() is WCallCommand.Start)
  }

  @Test
  fun resnapshotStopsStaleRingingOnlyForTheRequestedHost() {
    val first = invitation(1)
    val second = invitation(2).copy(callUUID = "second", contact = contact.copy(contactId = contact.contactId + 10))
    ChatModel.callManager.reportNewIncomingCall(first)
    ChatModel.callManager.reportNewIncomingCall(second)
    ChatModel.activeCallInvitation.value = first
    ChatModel.callManager.reconcileInvitations(1, emptyList())
    assertNull(ChatModel.callInvitations[first.contact.id])
    assertSame(second, ChatModel.callInvitations[second.contact.id])
    assertNull(ChatModel.activeCallInvitation.value)
    assertEquals(1, cancelledNotifications)
  }

  @Test
  fun snapshotAndQueuedInvitationProduceOneNotification() {
    val invitation = invitation(1)
    ChatModel.callManager.reconcileInvitations(1, listOf(invitation))
    ChatModel.callManager.reportNewIncomingCall(invitation)
    assertEquals(1, callNotifications)
    assertEquals(invitation.callUUID, ChatModel.activeCallInvitation.value?.callUUID)
  }
}
