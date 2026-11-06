package chat.simplex.app

import chat.simplex.common.model.*
import chat.simplex.common.platform.chatModel
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlin.test.*

class SimultaneousUIStateTest {
  private val user = User.sampleData
  private val received = ChatItem.getSampleData(id = 1, dir = CIDirection.DirectRcv(), status = CIStatus.RcvNew())
    .copy(content = CIContent.RcvMsgContent(MsgContent.MCText("received")))
  private val sent = ChatItem.getSampleData(id = 2, text = "sent on peer")
  private val conversation = Chat.sampleData.copy(chatItems = listOf(received, sent), chatStats = Chat.ChatStats(unreadCount = 1))
  private val oldUser = chatModel.currentUser.value
  private val oldHost = chatModel.currentRemoteHost.value
  private val oldChats = chatModel.chats.value.toList()
  private val oldItems = chatModel.chatsContext.chatItems.value.toList()
  private val oldChatId = chatModel.chatId.value
  private val oldUsers = chatModel.users.toList()

  @BeforeTest
  fun setup() {
    chatModel.resetUIState()
    chatModel.currentRemoteHost.value = null
    chatModel.currentUser.value = user
    chatModel.chatId.value = conversation.id
  }

  @AfterTest
  fun restore() {
    chatModel.resetUIState()
    chatModel.currentRemoteHost.value = oldHost
    chatModel.currentUser.value = oldUser
    chatModel.chatsContext.updateChats(oldChats)
    chatModel.chatsContext.applyUIItems(oldItems)
    chatModel.chatId.value = oldChatId
    chatModel.users.clear()
    chatModel.users.addAll(oldUsers)
    chatModel.updateChatTags(oldHost?.remoteHostId)
  }

  private fun snapshot(chat: Chat = conversation, revision: Long = 1) = CR.UIState(
    1, revision, user, listOf(UserInfo(user, chat.chatStats.unreadCount)), listOf(chat), chat, emptyList()
  )

  @Test
  fun repeatedSnapshotsDoNotDuplicateItemsOrUnreadCounters() {
    val state = snapshot()
    repeat(3) { assertTrue(chatModel.applyUIState(null, state, conversation.id)) }
    assertEquals(listOf(1L, 2L), chatModel.chatsContext.chatItems.value.map { it.id })
    assertEquals(1, chatModel.chats.value.single().chatStats.unreadCount)
    assertEquals(1, chatModel.chatsContext.chatState.unreadTotal.value)
    assertEquals(1, chatModel.users.single().unreadCount)
  }

  @Test
  fun snapshotReplacesEditedDeletedAndReadItemsAndManualUnread() {
    chatModel.applyUIState(null, snapshot(), conversation.id)
    val edited = sent.copy(meta = sent.meta.copy(itemText = "edited", itemEdited = true))
    val read = received.withStatus(CIStatus.RcvRead())
    val changed = conversation.copy(chatItems = listOf(read, edited), chatStats = Chat.ChatStats(unreadChat = true))
    chatModel.applyUIState(null, snapshot(changed, 2), conversation.id)
    assertEquals("edited", chatModel.chatsContext.chatItems.value.last().meta.itemText)
    assertEquals(0, chatModel.chatsContext.chatState.unreadTotal.value)
    assertTrue(chatModel.chats.value.single().chatStats.unreadChat)
    chatModel.applyUIState(null, snapshot(changed.copy(chatItems = listOf(read)), 3), conversation.id)
    assertEquals(listOf(1L), chatModel.chatsContext.chatItems.value.map { it.id })
  }

  @Test
  fun snapshotClosesDeletedChatAndRejectsAnOldProfile() {
    chatModel.applyUIState(null, snapshot(), conversation.id)
    val empty = CR.UIState(1, 2, user, listOf(UserInfo(user, 0)), emptyList(), null, emptyList())
    chatModel.applyUIState(null, empty, conversation.id)
    assertNull(chatModel.chatId.value)
    chatModel.currentUser.value = user.copy(userId = 99)
    assertFalse(chatModel.applyUIState(null, snapshot(), conversation.id))
    assertEquals(99L, chatModel.currentUser.value?.userId)
  }

  @Test
  fun oldSnapshotCannotOverwriteNewerStateOrANewSession() {
    chatModel.applyUIState(null, snapshot(revision = 10), conversation.id)
    assertFalse(chatModel.applyUIState(null, snapshot(revision = 9), conversation.id))
    val oldGeneration = chatModel.uiStateGeneration
    chatModel.resetUIState()
    assertFalse(chatModel.applyUIState(null, snapshot(revision = 11), conversation.id, oldGeneration))
    assertTrue(chatModel.applyUIState(null, snapshot(revision = 1), conversation.id))
  }

  @Test
  fun wireFormatDecodesInvalidationAndSnapshotWithoutLocalRoutingFields() {
    val event = json.decodeFromString<API>("""{"result":{"type":"uiStateChanged","uiVersion":1,"revision":12,"origin":"remote"}}""")
    assertEquals("remote", (event.result as CR.UIStateChanged).origin)
    val encoded = json.encodeToString<API>(API.Result(null, snapshot()))
    val decoded = json.decodeFromString<API>(encoded)
    assertTrue(decoded.result is CR.UIState)
    assertEquals(2, (decoded.result as CR.UIState).openChat!!.chatItems.size)
    assertEquals("/_ui snapshot @2 count=100", CC.UIState("@2", 100).cmdString)
  }
}
