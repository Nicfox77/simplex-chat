package chat.simplex.app

import chat.simplex.common.model.*
import chat.simplex.common.platform.NtfManager
import chat.simplex.common.platform.NotificationAction
import chat.simplex.common.platform.chatModel
import chat.simplex.common.views.call.RcvCallInvitation
import kotlin.test.Test
import kotlin.test.assertEquals

class SimultaneousNotificationTest {
  @Test
  fun onlyTheOwnerNotifiesForReceivedMessages() {
    var notifications = 0
    val manager = object : NtfManager() {
      override fun displayNotification(user: UserLike, chatId: String, displayName: String, msgText: String, image: String?, actions: List<Pair<NotificationAction, () -> Unit>>) { notifications++ }
      override fun notifyCallInvitation(invitation: RcvCallInvitation) = false
      override fun hasNotificationsForChat(chatId: String) = false
      override fun cancelNotificationsForChat(chatId: String) {}
      override fun cancelNotificationsForUser(userId: Long) {}
      override fun cancelCallNotification() {}
      override fun cancelAllNotifications() {}
      override fun showMessage(title: String, text: String) {}
      override fun androidCreateNtfChannelsMaybeShowAlert() {}
    }
    val oldChatId = chatModel.chatId.value
    try {
      chatModel.chatId.value = null
      val user = User.sampleData
      val info = Chat.sampleData.chatInfo
      val received = ChatItem.getSampleData(id = 1, dir = CIDirection.DirectRcv(), status = CIStatus.RcvNew())
        .copy(content = CIContent.RcvMsgContent(MsgContent.MCText("received")))
      manager.notifyMessageReceived(null, user, info, received)
      assertEquals(1, notifications)
      // The same event on the desktop and peer-sent items on either UI cannot
      // create a second alert or an action against the desktop's local store.
      manager.notifyMessageReceived(1, user, info, received)
      val sent = ChatItem.getSampleData(id = 2, text = "sent on peer")
      manager.notifyMessageReceived(null, user, info, sent)
      manager.notifyMessageReceived(1, user, info, sent)
      assertEquals(1, notifications)
    } finally {
      chatModel.chatId.value = oldChatId
    }
  }
}
