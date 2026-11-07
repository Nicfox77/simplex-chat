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

// Routing is editable only for an existing verified, enabled pairing. The core
// still authenticates the saved certificates and signing key on every attempt.
internal fun remoteRecoveryHostValid(host: String): Boolean {
  if (host.isEmpty() || host.length > 253) return false
  if (host.all { it.isDigit() || it == '.' }) {
    val octets = host.split('.').map { it.toIntOrNull() ?: return false }
    return octets.size == 4 && octets.all { it in 0..255 } && octets[0] == 100 && octets[1] in 64..127
  }
  return host.removeSuffix(".").split('.').all { label ->
    label.isNotEmpty() && label.length <= 63 && label.first() != '-' && label.last() != '-' &&
      label.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' }
  }
}
