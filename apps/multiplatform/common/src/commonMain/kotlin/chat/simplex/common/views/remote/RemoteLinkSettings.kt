package chat.simplex.common.views.remote

// An address/port edit must not leave the previous invitation available to scan or share.
// A null selected port requests a random port, so it also needs a new invitation.
internal fun <A> remoteLinkNeedsRefresh(
  invitationAddress: A?,
  invitationPort: Int?,
  selectedAddress: A?,
  selectedPort: Int?
): Boolean =
  (selectedAddress != null && selectedAddress != invitationAddress) || selectedPort != invitationPort

internal fun remoteLinkCanShare(directLinkHelp: Boolean, developerTools: Boolean, needsRefresh: Boolean): Boolean =
  (directLinkHelp || developerTools) && (!directLinkHelp || !needsRefresh)
