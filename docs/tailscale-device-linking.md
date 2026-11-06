# Android and Linux desktop linking over Tailscale

Android retries an established direct link after a dropped connection while the
Linux desktop retains its owned, authenticated listener. One trusted QR pairing
is sufficient for these reconnects. Pairing identities remain in the encrypted
chat database; the live invitation and its private session keys remain in memory.

**Process restart recovery is not implemented.** Restarting either application,
explicitly disconnecting, or closing the linking screen ends this reconnect
owner. After a desktop restart, select the saved linked phone and scan/paste a
fresh invitation. The implementation never restores old ephemeral private keys.
iOS application code and LAN discovery behavior are unchanged.

## Connect

1. Enable Tailscale on Android and Linux before opening the mobile-linking dialog.
2. On Linux, open **Linked mobiles**, select a saved mobile or **Link a mobile**,
   and choose **Use Tailscale address**, or select `tailscale0` in the dropdown.
3. Choose an unused fixed TCP port above 1023 if your access policy restricts
   ports. Press **Refresh** and check **Address in QR code**. Editing a selection
   does not change an already generated signed invitation.
4. On Android, open **Use from desktop**, scan the QR or paste the full `xrcp:`
   invitation, and verify the initial session code through a trusted channel.

The retained-listener path is enabled only for an explicitly selected IPv4
address in `100.64.0.0/10` and a peer that negotiates the Kotlin reconnect
capability. A missing selected interface fails closed. The usual LAN pairing and
multicast APIs retain their existing behavior. Tailscale multicast discovery is
not required. A bare IP or MagicDNS hostname cannot replace the signed invitation;
this implementation uses the stable tailnet IPv4 supplied by the interface and
does not rewrite signatures or add an IPv6/MagicDNS editor.

## Recovery, stop, and unlink

After a dropped TCP connection or a stalled event poll, the desktop closes and
joins the old transport and polling worker, releases that connection's server
handler, and waits for the paired phone on the same listener. Android retries
with exponential backoff (1, 2, 4, 8, 16, then 30 seconds, with 20% jitter), a
bounded native connection timeout, and a bounded confirmation wait. Android also
closes a negotiated direct session after 30 seconds without an incoming desktop
request, so silent TCP blackholes trigger recovery. This watchdog is raced with
the HTTP server and cancelled/joined with its owner. Each attempt
uses new phone DH keys, new KEM material, a new TLS channel binding, and new XRCP
traffic keys. The desktop's live invitation keys last only as long as its owner.

Android automatically confirms only a previously verified target whose saved
controller ID still matches. Both TLS identity pins and the XRCP identity check
remain mandatory. Identity/authentication/version failures terminate automatic
recovery; a deleted pairing is never automatically trusted again. Invitations
are not saved in preferences or files, and there is no retry before initial trust.

**Disconnect**, screen disposal, unlink, and stopping/resetting the chat controller
cancel Android's retry owner. Native commands that finish late are cleaned up
using a sequence-checked local abort before replacement operations proceed. A
connected phone sends an authenticated stop event so the desktop closes its
retained listener; the desktop sends an authenticated stop command so the phone
ends retries. These stop signals are bounded: if the network is already down,
the remote endpoint cannot learn the stop immediately. Stop/unlink on that
endpoint to close its waiting listener. No local listener survives local stop,
unlink, or controller shutdown.

The desktop retains a link only after successful pairing. Unpaired invitation
and confirmation waits remain bounded. Closing a pending dialog or removing an
active linked phone cancels its listener and workers. Stale disconnect handlers
and abort commands cannot cancel a newer session.

## Binding, firewall, and tailnet policy

The original simplexmq API advertises the selected address but calls
`startTCPServer ... Nothing`, binding a wildcard listener. The new retained
listener instead binds the actual selected IPv4. It adds no discovery service or
extra port. LAN listeners continue to use their original binding behavior.

Address binding alone does not authorize a peer. Restrict the desktop TCP port
in both the Linux firewall and the tailnet policy to the intended phone. Audit
other matching rules: Tailscale grants/ACL permissions are additive, so an existing
broad allow can also permit traffic. Do not forward this port from a public
router. SimpleX does not edit firewall or Tailscale configuration.

Inspect `ss -ltnp` while linking: the retained listener should show the selected
`100.x.y.z:port`, not `0.0.0.0:port` or `[::]:port`. Check reachability from the
intended phone and denial from an unauthorized tailnet peer and the desktop LAN
address. Tailscale's [grants documentation](https://tailscale.com/docs/features/access-control/grants)
and [netfilter documentation](https://tailscale.com/docs/reference/netfilter-modes)
explain the separate policy and host-firewall boundaries.

## Dependency and security review

`cabal.project` pins `Nicfox77/simplexmq` at
`985cf2b3e992884d2d8536458c012c456b889785`. It is the previous pinned upstream
`a0eec710` plus upstream certificate-chain validation commit `c89b00cf` and a
scoped owned-transport change. [Review the dependency diff](https://github.com/Nicfox77/simplexmq/compare/a0eec7104c706ab0dab2ad604f280a7130f7a22c...985cf2b3e992884d2d8536458c012c456b889785).
The Nix source hash includes the pinned submodules. Backend build scripts read
both dependency URL and revision from `cabal.project`.

The dependency adds per-connection release, an atomic active-session gate, a live
peer pin updated before publishing the first successful pairing, and
per-connection certificate capture. Handshakes may overlap, so the latest pin is
checked again after admission. Certificate-chain validation is preserved. Release
waits for the matching handler to finish; stale releases cannot close replacements.
Startup/bind failure closes the socket and resolves the startup wait.

The chat lifecycle adapts the relevant desktop loop from upstream draft #7338;
it does not transplant its detached cleanup threads or UI changes. Draft #7234
contains iOS-only changes and was not applied. The threat model includes another
tailnet/LAN peer possessing a copied invitation, forged certificate chains,
concurrent connection attempts, delayed events, repeated outages, explicit stop,
and unlink while a native connect completes.

Restart recovery still needs a separately reviewed, mutually authenticated fresh
invitation exchange with replay protection and explicit persisted enable/disable
state. The original invitation contains desktop ephemeral public keys, but those
private keys disappear when its listener dies. Retrying that invitation against
a new listener cannot substitute for fresh authenticated exchange. No such
restart feature is claimed here.

## Validation

The dependency's `xrcp-lifecycle` suite exercises repeated reconnects, fresh phone
DH keys, rejection of an unrelated phone and of an unrelated signing key presented
with the real pinned CA certificate, stale release, loss during confirmation,
owner shutdown, absent interface, and occupied port. It ran against this Linux
machine's actual `tailscale0` IPv4 (`100.101.0.9`): four examples passed. This tests
local routing to the tailnet address, not a connection from another device.

`DirectLinkReconnectTest` covers initial-trust gating, early/stale events, backoff,
stop during native connect, deleted pairing, transient recovery, and explicit
stop. All 18 focused Gradle tests passed (eleven reconnect tests and seven endpoint/QR
settings tests), together with shared Kotlin compilation for Android and Linux
desktop. The latest retry class also passed eleven standalone JUnit tests, including loss
during successful verification, early authentication failure, and stale terminal
events.
The native chat library compiled with GHC 9.6.6. The full Remote scope passed
serially and with four test workers: 66 examples, zero failures, 42 pre-existing pending compression variants
(24 active checks). This includes real transport loss/reconnect, fresh encrypted
commands after reconnection, stale abort, unlink, watchdog ownership, LAN multicast,
file transfers, and multiple profiles.

A separate live probe of the pinned dependency accepted TCP on `100.101.0.9`,
refused the same port on loopback and the LAN address, and refused the tailnet
port after owner shutdown. No firewall or tailnet policy was changed.

Reproduce the chat and Kotlin checks with:

```sh
cabal test simplex-chat-test -O0 --test-options='--match /Remote/ --jobs=4'
cd apps/multiplatform
./gradlew :common:compileKotlinDesktop :common:compileDebugKotlinAndroid
./gradlew :common:desktopTest --tests chat.simplex.app.DirectLinkReconnectTest \
  --tests chat.simplex.app.RemoteLinkSettingsTest
```

Android packages must include the native library rebuilt from this source revision;
a stock release native library does not implement the new core protocol capability.
Android native cross-compilation has not been run here.

An Android SDK was installed for Kotlin compilation; `adb devices` reported no attached
phones. Android UI, a real phone-to-desktop Tailscale outage/recovery, peer ACL
denial, and restart behavior are therefore not claimed as live-device verified.
PR #1's original Linux core CI passed. Its CLA Assistant failure reports the
missing upstream signing `PERSONAL_ACCESS_TOKEN` and is unrelated to code.
