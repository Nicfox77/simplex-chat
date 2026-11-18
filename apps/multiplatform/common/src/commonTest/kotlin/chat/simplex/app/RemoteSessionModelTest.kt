package chat.simplex.app

import chat.simplex.common.model.*
import chat.simplex.common.platform.chatModel
import kotlinx.serialization.decodeFromString
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RemoteSessionModelTest {
  private var previousHost: RemoteHostInfo? = null
  private var previousController: RemoteCtrlSession? = null
  private var previousControllers: Map<Long, RemoteCtrlSession> = emptyMap()

  @BeforeTest
  fun saveSession() {
    previousHost = chatModel.currentRemoteHost.value
    previousController = chatModel.remoteCtrlSession.value
    previousControllers = chatModel.remoteCtrlSessions.toMap()
    chatModel.remoteCtrlSessions.clear()
    chatModel.currentRemoteHost.value = null
    chatModel.remoteCtrlSession.value = null
  }

  @AfterTest
  fun restoreSession() {
    chatModel.currentRemoteHost.value = previousHost
    chatModel.remoteCtrlSession.value = previousController
    chatModel.remoteCtrlSessions.clear()
    chatModel.remoteCtrlSessions.putAll(previousControllers)
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
  fun authorizedReconnectKeepsThePhoneAsFileOwner() {
    val desktop = RemoteCtrlInfo(1, "Desktop", null, recoveryEnabled = true)
    chatModel.remoteCtrlSession.value = RemoteCtrlSession(
      ctrlAppInfo = null,
      appVersion = "",
      sessionState = UIRemoteCtrlSessionState.Connecting(desktop)
    )
    assertTrue(chatModel.remoteCtrlSession.value!!.restartRecovery)
    assertFalse(chatModel.remoteCtrlSession.value!!.active)
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
  @Test
  fun closingOneDesktopKeepsOtherHostedSessionsActive() {
    val first = RemoteCtrlInfo(1, "Laptop", RemoteCtrlSessionState.Connected("first"))
    val second = RemoteCtrlInfo(2, "Workstation", RemoteCtrlSessionState.Connected("second"))
    chatModel.remoteCtrlSessions[1] = RemoteCtrlSession(null, "", UIRemoteCtrlSessionState.Connected(first, "first"))
    chatModel.remoteCtrlSessions[2] = RemoteCtrlSession(null, "", UIRemoteCtrlSessionState.Connected(second, "second"))
    assertTrue(chatModel.hasHostedSession())
    assertTrue(chatModel.hasActiveHostedSession())
    chatModel.remoteCtrlSessions.remove(1)
    assertTrue(chatModel.hasHostedSession())
    assertTrue(chatModel.hasActiveHostedSession())
    assertFalse(chatModel.connectedToRemote())
    chatModel.remoteCtrlSessions[2] = RemoteCtrlSession(null, "", UIRemoteCtrlSessionState.Connecting(second))
    assertTrue(chatModel.hasHostedSession())
    assertFalse(chatModel.hasActiveHostedSession())
    chatModel.remoteCtrlSessions.clear()
    assertFalse(chatModel.hasHostedSession())
  }

  @Test
  fun stoppedEventsIdentifyOnlyTheirOwnDesktop() {
    val api = json.decodeFromString<API>("""{"result":{"type":"remoteCtrlStopped","rcsState":{"type":"connected","sessionCode":"code"},"rcStopReason":{"type":"disconnected"},"sessionSeq":7,"remoteCtrlId_":2}}""")
    val event = api.result as CR.RemoteCtrlStopped
    kotlin.test.assertEquals(2L, event.remoteCtrlId_)
    kotlin.test.assertEquals(7, event.sessionSeq)
  }

  @Test
  fun linkedListShowsBothConnectionsEvenWhenOnlyOneIsSelected() {
    val first = RemoteCtrlInfo(1, "Laptop", null, recoveryEnabled = true)
    val second = RemoteCtrlInfo(2, "Laptop", null, recoveryEnabled = true)
    chatModel.remoteCtrlSessions[1] = RemoteCtrlSession(null, "", UIRemoteCtrlSessionState.Connected(first, "first"))
    chatModel.remoteCtrlSessions[2] = RemoteCtrlSession(null, "", UIRemoteCtrlSessionState.Connected(second, "second"))
    chatModel.remoteCtrlSession.value = chatModel.remoteCtrlSessions[2]

    // A just-paired desktop is visible before the saved list refresh completes.
    val rows = linkedDesktopRows(listOf(first), chatModel.remoteCtrlSessions.toMap())
    assertEquals(listOf(1L, 2L), rows.map { it.remoteCtrl.remoteCtrlId })
    assertTrue(rows.all { it.status == LinkedDesktopStatus.Connected })
  }

  @Test
  fun linkedListDoesNotKeepDisconnectedDesktopConnectedFromStaleSavedState() {
    val first = RemoteCtrlInfo(1, "Laptop A", RemoteCtrlSessionState.Connected("old"), recoveryEnabled = true)
    val second = RemoteCtrlInfo(2, "Laptop B", null, recoveryEnabled = true)
    val sessions = mapOf(2L to RemoteCtrlSession(null, "", UIRemoteCtrlSessionState.Connecting(second)))
    val rows = linkedDesktopRows(listOf(first, second), sessions)
    assertEquals(listOf(LinkedDesktopStatus.Disconnected, LinkedDesktopStatus.Reconnecting), rows.map { it.status })
    assertEquals(2L, rows[1].session?.recoveryCtrl?.remoteCtrlId)
  }

  @Test
  fun linkedListShowsConfirmationWithoutMarkingTheSessionConnected() {
    val desktop = RemoteCtrlInfo(3, "Laptop C", null)
    val session = RemoteCtrlSession(null, "", UIRemoteCtrlSessionState.PendingConfirmation(desktop, "code"))
    val row = linkedDesktopRows(emptyList(), mapOf(3L to session)).single()
    assertEquals(LinkedDesktopStatus.PendingConfirmation, row.status)
    assertFalse(row.session!!.active)
  }
}
