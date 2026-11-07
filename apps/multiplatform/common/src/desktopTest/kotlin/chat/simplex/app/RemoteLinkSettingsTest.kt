package chat.simplex.app

import chat.simplex.common.model.*
import chat.simplex.common.views.remote.remoteRecoveryHostValid
import chat.simplex.common.views.remote.remoteLinkCanShare
import chat.simplex.common.views.remote.remoteLinkNeedsRefresh
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteLinkSettingsTest {
  @Test fun invitationCapabilityCannotKeepAnUnverifiedSessionInBackground() {
    val info = CtrlAppInfo(AppVersionRange("7.1.0", "7.1.0"), "desktop", reconnect = true, restart = true)
    val states = listOf(UIRemoteCtrlSessionState.Starting, UIRemoteCtrlSessionState.Connecting(), UIRemoteCtrlSessionState.PendingConfirmation(sessionCode = "code"))
    states.forEach { assertFalse(RemoteCtrlSession(info, "", it).restartRecovery) }
  }

  @Test fun verifiedDatabaseAuthorizationKeepsTheOwnerDuringRecovery() {
    val rc = RemoteCtrlInfo(7, "desktop", null, recoveryEnabled = true)
    val states = listOf(UIRemoteCtrlSessionState.Connected(rc, "code"), UIRemoteCtrlSessionState.Connecting(rc), UIRemoteCtrlSessionState.PendingConfirmation(rc, "code"))
    states.forEach { assertTrue(RemoteCtrlSession(null, "", it).restartRecovery) }
    assertFalse(RemoteCtrlSession(null, "", UIRemoteCtrlSessionState.Connecting(rc.copy(recoveryEnabled = false))).restartRecovery)
  }

  @Test fun recoveryAddressAcceptsTailnetIPv4AndMagicDNS() {
    listOf("100.64.0.1", "100.127.255.254", "desktop", "desktop.tailnet.ts.net", "Desktop-1.tailnet.ts.net.").forEach { assertTrue(it, remoteRecoveryHostValid(it)) }
  }

  @Test fun recoveryAddressRejectsLinksPortsAndMalformedHosts() {
    listOf("", "192.168.1.1", "100.128.0.1", "100.64.0.999", "100.64.0.1:5228", "https://desktop", "-desktop", "desktop-", "desktop..ts.net", "desktop\n", "a".repeat(64), "..").forEach { assertFalse(it, remoteRecoveryHostValid(it)) }
  }

  @Test
  fun switchingFromLanToTailscaleRequiresANewInvitation() {
    assertFalse(remoteLinkNeedsRefresh("192.168.1.5", 5228, "192.168.1.5", 5228))
    assertTrue(remoteLinkNeedsRefresh("192.168.1.5", 5228, "100.101.102.103", 5228))
    // The QR is usable again only after the returned invitation uses the selected endpoint.
    assertFalse(remoteLinkNeedsRefresh("100.101.102.103", 5228, "100.101.102.103", 5228))
  }

  @Test
  fun changingOrRandomizingThePortRequiresANewInvitation() {
    assertTrue(remoteLinkNeedsRefresh("100.101.102.103", 5228, "100.101.102.103", 5229))
    assertTrue(remoteLinkNeedsRefresh("100.101.102.103", 5228, "100.101.102.103", null))
    assertFalse(remoteLinkNeedsRefresh("100.101.102.103", 5229, "100.101.102.103", 5229))
  }

  @Test
  fun revertingAnEditAllowsTheOriginalInvitation() {
    assertTrue(remoteLinkNeedsRefresh("192.168.1.5", 5228, "100.101.102.103", 5229))
    assertFalse(remoteLinkNeedsRefresh("192.168.1.5", 5228, "192.168.1.5", 5228))
  }

  @Test
  fun noAddressPreferenceKeepsTheAdvertisedLanAddress() {
    assertFalse(remoteLinkNeedsRefresh("192.168.1.5", 5228, null, 5228))
    assertTrue(remoteLinkNeedsRefresh("192.168.1.5", 5228, null, null))
  }

  @Test
  fun selectingADifferentInterfaceAlsoRequiresRefresh() {
    assertTrue(remoteLinkNeedsRefresh("100.101.102.103" to "eth0", 5228, "100.101.102.103" to "tailscale0", 5228))
    assertFalse(remoteLinkNeedsRefresh("100.101.102.103" to "tailscale0", 5228, "100.101.102.103" to "tailscale0", 5228))
  }

  @Test
  fun androidAndLinuxCanOnlyShareTheCurrentInvitation() {
    for (developerTools in listOf(false, true)) {
      assertTrue(remoteLinkCanShare(directLinkHelp = true, developerTools, needsRefresh = false))
      assertFalse(remoteLinkCanShare(directLinkHelp = true, developerTools, needsRefresh = true))
    }
  }

  @Test
  fun otherPlatformsKeepTheirDeveloperOnlyShareBehavior() {
    for (needsRefresh in listOf(false, true)) {
      assertTrue(remoteLinkCanShare(directLinkHelp = false, developerTools = true, needsRefresh))
      assertFalse(remoteLinkCanShare(directLinkHelp = false, developerTools = false, needsRefresh))
    }
  }
}
