package chat.simplex.common.views.call

import chat.simplex.common.AppLock
import chat.simplex.common.model.*
import chat.simplex.common.platform.*
import chat.simplex.common.views.helpers.withBGApi
import chat.simplex.common.views.helpers.generalGetString
import chat.simplex.common.views.helpers.AlertManager
import chat.simplex.res.*
import kotlinx.datetime.Clock
import kotlin.time.Duration.Companion.minutes

class CallManager(val chatModel: ChatModel) {
  fun reportNewIncomingCall(invitation: RcvCallInvitation) {
    Log.d(TAG, "CallManager.reportNewIncomingCall")
    with (chatModel) {
      if (callInvitations[invitation.contact.id]?.let { it.remoteHostId == invitation.remoteHostId && it.callUUID == invitation.callUUID } == true) return
      callInvitations[invitation.contact.id] = invitation
      if (invitation.user.showNotifications) {
        if (Clock.System.now() - invitation.callTs <= 3.minutes) {
          invitation.sentNotification = ntfManager.notifyCallInvitation(invitation)
          activeCallInvitation.value = invitation
        } else {
          val contact = invitation.contact
          ntfManager.displayNotification(user = invitation.user, chatId = contact.id, displayName = contact.displayName, msgText = invitation.callTypeText)
        }
      }
    }
  }

  internal fun reconcileInvitations(rhId: Long?, pending: List<RcvCallInvitation>) {
    val uuids = pending.map { it.callUUID }.toSet()
    chatModel.callInvitations.values.filter { it.remoteHostId == rhId && it.callUUID !in uuids }.toList().forEach {
      chatModel.callInvitations.remove(it.contact.id)
      reportCallRemoteEnded(it)
    }
    pending.forEach { invitation ->
      val call = chatModel.activeCall.value
      if (call?.let { it.remoteHostId == rhId && it.callUUID == invitation.callUUID } != true) reportNewIncomingCall(invitation.copy(remoteHostId = rhId))
    }
  }

  fun acceptIncomingCall(invitation: RcvCallInvitation) = withBGApi {
    val call = chatModel.activeCall.value
    val contactInfo = chatModel.controller.apiContactInfo(invitation.remoteHostId, invitation.contact.contactId)
    val profile = contactInfo?.second ?: invitation.user.profile.toProfile()
    // Claim before opening a microphone/camera or ending a different local call.
    if (!chatModel.controller.apiClaimCall(invitation.remoteHostId, invitation.contact, invitation.callUUID)) {
      chatModel.callInvitations.remove(invitation.contact.id)
      reportCallRemoteEnded(invitation)
      showCallUnavailable()
      return@withBGApi
    }
    // In case the same contact calling while previous call didn't end yet (abnormal ending of call from the other side)
    if (call == null || (call.remoteHostId == invitation.remoteHostId && call.contact.id == invitation.contact.id)) {
      justAcceptIncomingCall(invitation = invitation, profile)
    } else {
      chatModel.switchingCall.value = true
      try {
        endCall(call = call)
        justAcceptIncomingCall(invitation = invitation, profile)
      } finally {
        chatModel.switchingCall.value = false
      }
    }
  }

  private fun justAcceptIncomingCall(invitation: RcvCallInvitation, userProfile: Profile) {
    with (chatModel) {
      activeCall.value?.androidCallState?.close()
      activeCall.value = Call(
        remoteHostId = invitation.remoteHostId,
        userProfile = userProfile,
        contact = invitation.contact,
        callUUID = invitation.callUUID,
        callState = CallState.InvitationAccepted,
        initialCallType = invitation.callType.media,
        hasSharedKey = invitation.sharedKey != null,
        androidCallState = platform.androidCreateActiveCallState()
      )
      showCallView.value = true
      val useRelay = controller.appPrefs.webrtcPolicyRelay.get()
      val iceServers = getIceServers()
      callCommand.add(WCallCommand.Start(
        media = invitation.callType.media,
        aesKey = invitation.sharedKey,
        iceServers = iceServers,
        relay = useRelay,
        canReconnect = invitation.contact.callReconnectSupported
      ))
      callInvitations.remove(invitation.contact.id)
      if (invitation.contact.id == activeCallInvitation.value?.contact?.id) {
        activeCallInvitation.value = null
        ntfManager.cancelCallNotification()
      }
    }
  }

  suspend fun endCall(call: Call) {
    with(chatModel) {
      // If there is active call currently and it's with other contact, don't interrupt it
      if (activeCall.value != null && !(activeCall.value?.remoteHostId == call.remoteHostId && activeCall.value?.contact?.id == call.contact.id)) return

      // Don't destroy WebView if you plan to accept next call right after this one
      if (!switchingCall.value) {
        AppLock.appWasHidden()
        showCallView.value = false
        activeCall.value?.androidCallState?.close()
        activeCall.value = null
        activeCallViewIsCollapsed.value = false
        platform.androidCallEnded()
      }
      if (call.callState == CallState.Ended) {
        Log.d(TAG, "CallManager.endCall: call ended")
      } else {
        Log.d(TAG, "CallManager.endCall: ending call...")
        //callCommand.add(WCallCommand.End)
        controller.apiEndCall(call.remoteHostId, call.contact)
      }
    }
  }

  suspend fun signallingFailed(call: Call) {
    endCall(call.copy(callState = CallState.Ended))
    showCallUnavailable()
  }

  private fun showCallUnavailable() {
    AlertManager.shared.showAlertMsg(
      generalGetString(MR.strings.cant_call_contact_alert_title),
      generalGetString(MR.strings.call_unavailable_on_this_device)
    )
  }

  fun endCall(invitation: RcvCallInvitation) {
    with (chatModel) {
      callInvitations.remove(invitation.contact.id)
      if (invitation.contact.id == activeCallInvitation.value?.contact?.id) {
        activeCallInvitation.value = null
        ntfManager.cancelCallNotification()
      }
      withBGApi {
        if (!controller.apiRejectCall(invitation.remoteHostId, invitation.contact)) {
          Log.e(TAG, "apiRejectCall error")
        }
      }
    }
  }

  fun reportCallRemoteEnded(invitation: RcvCallInvitation) {
    if (chatModel.activeCallInvitation.value?.let { it.remoteHostId == invitation.remoteHostId && it.contact.id == invitation.contact.id } == true) {
      chatModel.activeCallInvitation.value = null
      ntfManager.cancelCallNotification()
    }
  }
}
