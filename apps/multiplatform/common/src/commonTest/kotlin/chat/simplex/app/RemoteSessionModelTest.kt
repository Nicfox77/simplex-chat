package chat.simplex.app

import chat.simplex.common.model.*
import chat.simplex.common.platform.chatModel
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RemoteSessionModelTest {
  private var previousHost: RemoteHostInfo? = null
  private var previousController: RemoteCtrlSession? = null

  @BeforeTest
  fun saveSession() {
    previousHost = chatModel.currentRemoteHost.value
    previousController = chatModel.remoteCtrlSession.value
    chatModel.currentRemoteHost.value = null
    chatModel.remoteCtrlSession.value = null
  }

  @AfterTest
  fun restoreSession() {
    chatModel.currentRemoteHost.value = previousHost
    chatModel.remoteCtrlSession.value = previousController
  }

  @Test
  fun phoneHostingDesktopStillUsesLocalFiles() {
    val desktop = RemoteCtrlInfo(1, "Desktop", RemoteCtrlSessionState.Connected("code"))
    chatModel.remoteCtrlSession.value = RemoteCtrlSession(
      ctrlAppInfo = null,
      appVersion = "",
      sessionState = UIRemoteCtrlSessionState.Connected(desktop, "code")
    )
    assertTrue(chatModel.remoteCtrlSession.value!!.active)
    assertFalse(chatModel.connectedToRemote())
  }

  @Test
  fun desktopViewingPhoneUsesRemoteFiles() {
    chatModel.currentRemoteHost.value = RemoteHostInfo(
      remoteHostId = 1,
      hostDeviceName = "Phone",
      storePath = "",
      bindAddress_ = null,
      bindPort_ = null,
      sessionState = null
    )
    assertTrue(chatModel.connectedToRemote())
  }
}
