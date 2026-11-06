# Android and Linux desktop linking over Tailscale

This branch implements a small direct-link UX improvement, not automatic session
recovery. It uses the existing XRCP QR/invitation flow and stored pairing identities.
It does not change the Haskell core, simplexmq dependency, listener lifetime, ports,
TLS configuration, session verification, or stop/unlink behavior. No session keys
or invitations are persisted in app storage by this feature. iOS is untouched;
the new desktop help is enabled only on Linux.

## Connect

1. Connect Android and Linux to the intended tailnet and enable the desktop's
   `tailscale0` interface before opening SimpleX's mobile-linking dialog.
2. On the desktop, open **Linked mobiles** and select the already linked
   mobile, or **Link a mobile** for a new device. Choose **Use Tailscale address**
   (available when `tailscale0` is in the reported addresses), or select the
   intended address in the existing dropdown. This is an explicit choice; LAN
   defaults and address ordering remain unchanged.
3. If the address or port changed, press **Refresh**. Check **Address in QR code**
   against the intended Tailscale IPv4 and port. The shortcut changes the pending
   selection, not the already generated invitation. Share link is hidden while
   the invitation needs refreshing on Android/Linux.
4. On Android, open **Use from desktop**. Scan the QR, or use **Share link** on
   Linux and **Paste desktop address** on Android, then **Connect to desktop**.
   Transfer the full, unmodified `xrcp:` invitation over a channel you trust.
   A bare IP or MagicDNS name cannot replace the signed invitation. Compare and
   verify the session code as in normal pairing.

Multicast is unnecessary for this flow. Disable **Discoverable via local network**
on the desktop and **Discover via local network** in Android's linked-desktop
options if desired. If Android is already searching, tap **Scan QR code** to leave
discovery and reach the scan/paste screen. The feature does not alter these
preferences automatically.

Use the IPv4 reported for `tailscale0`. This change does not add a MagicDNS editor
or rewrite the signed invitation host. If Tailscale is missing from the list,
enable it and reopen the dialog. The dependency treats the selection as a
preference and can fall back to another address if it becomes unavailable; always
check the actual address shown after refreshing.

## Reconnect and stop

After transport loss, the current core stops the session and desktop listener.
Select the existing linked mobile on the desktop to generate a fresh invitation;
on Android leave any searching state and scan/paste that invitation again. Stored
pairing identities are reused, but a fresh authenticated connection is required.
Leave session verification enabled if you want to compare each new session code.
The same manual flow is needed after a desktop restart. There is no background
retry or QR-free recovery in this branch.

**Disconnect**, closing a pending linking dialog, and **Unlink/Delete** retain
their upstream behavior. This feature never restarts a listener after those
actions. After unlinking, intentional future pairing uses the normal new-device
verification flow.

## Existing listener exposure and mitigation

Selecting `tailscale0` or a Tailscale IP changes the invitation address; it **does
not bind the listener to that interface**. The pinned simplexmq revision
`a0eec7104c706ab0dab2ad604f280a7130f7a22c` calls
`startTCPServer started Nothing` from `Simplex.RemoteControl.Discovery.startTLSServer`.
The transport resolves this with `AI_PASSIVE` and prefers IPv6, otherwise IPv4,
so it uses a wildcard address. Actual reachability depends on the OS and firewall.
This behavior predates this branch and is unchanged. XRCP authentication still
applies, but address selection is not a firewall boundary.

For a Tailscale-only deployment:

- Choose a fixed, unused TCP port above 1023 in the existing port field and refresh
  the invitation. This makes firewall rules predictable; the feature opens no
  additional port.
- In the Linux host firewall, deny inbound traffic to that TCP port on every
  interface except `tailscale0`, covering both IPv4 and IPv6. Permit the intended
  Android peer on `tailscale0` only. Ensure these restrictions apply despite
  existing broad allow rules or Tailscale-managed chains. Do not add a public
  router port-forward.
- In the tailnet access policy, allow only the intended phone identity/device to
  reach this desktop and TCP port. Audit other matching grants/ACL rules: a broad
  existing allow can defeat a narrower rule. Tailnet rules alone do not restrict
  direct LAN/public traffic to the desktop wildcard listener.
- While a linking dialog/session is active, inspect `ss -ltnp` on Linux. Verify
  from the intended phone that the Tailscale endpoint is reachable and from a
  separate LAN peer that the desktop's LAN address at the same port is blocked.
  Also verify an unauthorized tailnet peer cannot connect. These are deployment
  checks; they have not been exercised against a real tailnet for this branch.

See Tailscale's [netfilter modes](https://tailscale.com/docs/reference/netfilter-modes)
for how its firewall chains accept tailnet traffic, and
[grants](https://tailscale.com/docs/features/access-control/grants) for limiting
network access. These policies and the host firewall must be configured separately;
SimpleX does not manage them.

## Why recovery was not transplanted from draft #7338

The locally fetched draft `upstream/pr-7338` adds a desktop loop that retains the
listener and consumes successive XRCP steps. It also contains substantial session,
stop, and UI changes. `upstream/pr-7234` has only iOS changes. Neither was
cherry-picked.

In the currently pinned XRCP client, the server callback hands the TLS connection
to the app and then waits on a shared `endSession` TMVar. Its exported host-client
API only exposes `action` and whole-client cancellation; there is no per-connection
release. Reusing the initial listener also retains its originally captured
`knownHost` TLS policy (which is empty for new pairing). A reliable recovery design
must account for callback cleanup, pin the successfully paired peer, distinguish
explicit stop from transport loss, and reject stale callbacks before handing out
commands. Simply retaining the QR or retrying the loop is insufficient evidence
of safe recovery. This branch takes the authorized UX fallback rather than
extending that listener's lifetime or changing its authentication policy.

Desktop restart recovery additionally needs a fresh authenticated invitation
exchange or a reviewed secret-persistence design: the invitation's session
signing/DH private keys are currently generated in memory. This branch persists
none of them.

## Validation

`RemoteLinkSettingsTest` covers LAN-to-Tailscale selection, port changes, random
ports, reverting edits, retaining LAN defaults, switching interfaces, and blocking
stale invitation sharing on Android/Linux while preserving other platforms'
developer-only sharing behavior. The same refresh predicate gates the QR overlay
and Linux/Android link sharing.

Run the focused desktop tests with:

```sh
cd apps/multiplatform
./gradlew :common:desktopTest --tests chat.simplex.app.RemoteLinkSettingsTest
```

Observed in this development environment: all seven JUnit tests passed when the
production helper and test source were compiled independently with cached Kotlin
2.2.21, using language/API version 2.1 and JVM target 11. The platform expect/actual
declarations were also compiled independently and checked on the JVM with Linux,
macOS, and Windows OS/architecture inputs, plus the Android actual declaration.
The full Gradle task was attempted but stopped during project configuration
because the Android SDK is not installed; this does not validate the Compose UI
or an Android build. The base resource XML parsed successfully and the four new
string keys were checked for uniqueness and nonempty values.

Manual UI checks still required on built Android/Linux apps: choose `tailscale0`,
confirm the old QR and Share link action are hidden until refresh, check the displayed endpoint,
paste a fresh invitation and verify the session, disconnect/unlink, and confirm no
automatic restart. Repeat normal LAN pairing. No live Tailscale, reconnect, or
full application validation is claimed by the unit tests.
