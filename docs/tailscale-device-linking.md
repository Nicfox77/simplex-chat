# Android phone and Linux desktop over Tailscale

After one verified QR pairing on a selected tailnet IPv4, Android reconnects the
linked session after network loss and after application restart. The phone
remains the chat host; Linux uses its remote UI. Recovery uses the existing
pairing identities in the encrypted chat database and a fresh, authenticated
invitation exchange. Desktop invitation private keys are never persisted.

Both applications need this fork's rebuilt native library. Existing pairings
from earlier versions have recovery disabled until a direct session is verified
with the new version. iOS application code and LAN multicast behavior are unchanged.

## Scope and testing

The phone owns the chat store and messaging connections. Android and one Linux
desktop can send and view messages concurrently. Multiple active desktops and
iOS hosting of the concurrent UI protocol are not implemented. Both applications
must use matching native and Kotlin sources.

After pairing, send messages from both devices, then edit, react, delete and
read from each. Interrupt the laptop network while leaving both apps running.
Send from the phone during the outage, restore connectivity, and check that the
desktop catches up and can send again. An interrupted send may already have
reached the phone; check there before manually retrying. The app does not replay
uncertain sends. Repeat with application restarts and phone backgrounding, then
explicitly disconnect and unlink to verify that recovery stops.

## Pair once

1. Enable Tailscale on Android and Linux.
2. On Linux, open **Linked mobiles**, select a saved mobile or **Link a mobile**,
   select `tailscale0` (or **Use Tailscale address**), and press **Refresh**.
3. Check **Address in QR code**. A fixed unused TCP port above 1023 is useful for
   tailnet/firewall rules; an initially random port is also saved after pairing.
4. On Android, open **Use from desktop**, scan the QR or paste the full `xrcp:`
   invitation, and verify the first session code through a trusted channel.

Selecting the tailnet address and verifying the session enables restart recovery
on both devices when both advertise the capability. Closing the Android linking
screen keeps this negotiated link and its service running. **Disconnect** and
unlink explicitly disable it. An unverified invitation never enables recovery.

The listener binds the actual selected IPv4, rather than a wildcard. Only an
explicit selection in `100.64.0.0/10` enables this path. A missing selected
interface fails closed. There is no multicast requirement or additional port.

After verification, Android's **Linked desktops** list offers **Recovery address**
in the desktop's long-press menu. Enter a tailnet IPv4 or MagicDNS name, such as
`desktop.example.ts.net`. This changes the route for the next invitation fetch,
using the saved port. DNS is never an authentication mechanism: the saved TLS
certificate and signing identity must still match. The actual XRCP session uses
the endpoint in the freshly signed invitation. A bare address cannot perform an
initial pairing, change a trust pin, or re-enable a disconnected pairing.

## Authenticated restart protocol

The desktop database saves an enable flag and its selected interface/address and
actual bound port, alongside the existing long-term CA and signing identities.
The phone saves the enabled desktop's endpoint alongside its existing pairing.
No invitation URI, desktop session signing/DH private key, KEM material, TLS
session, or XRCP traffic key is saved in preferences or new files.

On Linux application startup, after the main database is unlocked and its event
receiver is running, enabled listeners are reconstructed with **new** session
Ed25519 and X25519 key pairs and a new signed invitation. The paired phone's TLS
CA pin is loaded before listening. Only restored, previously authorized listeners
wait indefinitely for their phone; an ordinary unpaired invitation still expires.

Android startup reads the main database after unlock and starts the retry owner
for its enabled pairing. Only one controller can be enabled by verification. An
ambiguous database with multiple enabled controllers is not resolved by guessing.
The retry target contains a database pairing ID, not an old invitation.

Each recovery attempt performs:

1. Connect to the saved IP/MagicDNS address and port using TLS with ALPN
   `simplex-xrcp-invitation/1`. The phone pins the saved desktop CA. The desktop
   validates the phone's certificate chain and proof of possession and checks the
   saved phone CA pin, including a connection-local check after handshake.
2. Receive the current signed invitation inside that fresh mutual TLS channel.
   Verify both invitation signatures and compare **both** the CA fingerprint and
   long-term Ed25519 signing key with the stored desktop identity. Missing ALPN,
   invalid signatures, or changed identity fail closed; there is no QR fallback
   or implicit new trust. The fetch does not publish an application session or
   acquire the XRCP active-session gate.
3. Close the fetch connection and establish normal XRCP using the new invitation.
   Its normal TLS pinning, HELLO identity checks, fresh phone DH/KEM material,
   verification code, and signed/encrypted commands remain mandatory. Automatic
   confirmation is allowed only for the same saved controller ID.

TLS handshake freshness and record authentication provide replay protection for
invitation delivery; no reusable bearer recovery secret or timestamp-only check
is introduced. After desktop restart, the old invitation cannot decrypt a HELLO
on the new listener. Within one listener lifetime its desktop invitation keys
remain memory-only, as in the existing retained-listener implementation. Existing
phone DH persistence for LAN announcement decryption is unchanged; the recovery
fetch does not use those DH keys, and every XRCP connect generates new phone keys.

The fetch and native connection have bounded timeouts. Android retries with
exponential backoff (1, 2, 4, 8, 16, then 30 seconds, with 20% jitter), bounded
confirmation waits, and sequence-checked cleanup of native results that finish
after cancellation. Protocol/identity failures terminate automatic authorization;
ordinary network loss retains it. The desktop event poll and phone idle watchdog
also detect silent TCP blackholes. Old transport workers are closed and joined
before a replacement is admitted; stale releases cannot close a newer session.

## Stop, unlink, and process lifecycle

**Disconnect**, unlink, and explicitly stopping chat revoke saved recovery
locally, including when the retry owner is between attempts. An authenticated
stop over a live session disables recovery on the receiving side too. Unlink
removes the pairing identity and recovery metadata. A routing edit cannot restore
an absent enable flag. Pending handlers are cancelled and joined, and revocation
is written again after cleanup so an in-flight verification cannot re-enable it.

Process cleanup closes all listeners and workers but preserves the enabled
pairing for the next unlocked application startup. Thus normal application exit,
process termination, or a transient outage does not act as an explicit unlink.
Opening an already restored listener's desktop status screen does not start a
second listener. Opening Android's linking screen does not disconnect a restored
session.

If the network is already down, a remote endpoint cannot learn a stop immediately.
Stop/unlink on that endpoint to revoke its local authorization as well. Local
stop/unlink is durable; a new process cannot reopen that endpoint's listener or
automatically connect using its disabled row.

Recovery requires the applications to run and their databases to be unlocked.
Android may restrict or kill background services; this implementation does not
promise recovery while Android prevents execution or before database unlock.
On Linux, start Tailscale before opening SimpleX. If the interface is absent or
the saved port is occupied at startup, restore logs the failure and binds no
fallback address. Resolve the conflict and restart the app, or explicitly open
the saved phone's linking screen. A changed port requires a fresh pairing
invitation; a MagicDNS route can accommodate a changed tailnet IP on the same
selected interface.

## Firewall and dependency boundary

Restrict the selected desktop TCP port in the Linux firewall and tailnet policy
to the intended phone. Tailscale permissions are additive: audit broad allow
rules too. SimpleX does not change firewall or Tailscale configuration. Do not
forward the port from a public router. Check `ss -ltnp`: the listener should show
`100.x.y.z:port`, not `0.0.0.0:port` or `[::]:port`. Check denial from an
unauthorized peer and the desktop LAN address, as well as intended phone access.

`cabal.project` pins `Nicfox77/simplexmq@10e75b56891deef9064474265208ba39beb08dd9`.
[Restart transport diff](https://github.com/Nicfox77/simplexmq/compare/985cf2b3e992884d2d8536458c012c456b889785...10e75b56891deef9064474265208ba39beb08dd9). Its
baseline is upstream `a0eec710` plus certificate-chain validation `c89b00cf`, owned
listener/session cleanup, and the mutual-TLS invitation fetch described above.
The dependency contains the transport lifecycle/security tests. Nix and backend
build scripts use the same pinned revision; the Nix hash includes submodules.
