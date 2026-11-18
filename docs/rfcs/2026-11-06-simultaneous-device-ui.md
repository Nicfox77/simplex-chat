# Simultaneous Android phone and Linux desktop UI

Status: implemented behind negotiated UI protocol 2, enabled by the Kotlin
apps at core startup. Android hosting and up to eight Linux desktops are supported;
iOS hosting is outside this change.

The Android phone is the only owner of the database, ratchets, agent and network
connections. The Linux desktop uses authenticated, encrypted XRCP commands,
events and file transfer. There is no second synchronized database, shared
SQLite file, new cryptographic scheme, or server-side synchronization.
Both devices need the core and Kotlin code from this branch. An old native
library fails the startup capability check; a peer without UI protocol 2 fails
pairing. Updating just the APK/JAR sources with release native libraries is not
sufficient.

## Delivery and reconciliation

The phone's local receiver and each authenticated desktop session have independent
bounded event queues. Eligible asynchronous events are fanned out atomically to
all subscribers; they never compete to read the same queue. Platform-store callbacks,
pairing/lifecycle events stay on the phone. Call invitations are shared; media
negotiation goes to the UI running WebRTC. Command replies
and errors return only through the initiating request. Successful send, edit,
delete, read/unread, reaction, contact/group and file acceptance mutations publish
`uiStateChanged` invalidations with protocol version, revision and explicit
`local`/`remote` origin. Both frontends reconcile their projections; the reply
payload is never broadcast as an unsolicited notification.

`/_ui enable` opts a Kotlin frontend into protocol 2 before pairing. Legacy
terminal sessions without this capability retain exclusive event routing.
`/_ui snapshot [chat-ref] count=N` returns the active user, users and unread
counts, chat previews and read/manual-unread counters, tags and optional loaded
chat items in one store transaction. Its revision is sampled before the
transaction. Events committed during or after that snapshot remain queued.
Snapshots replace items and counters, rather than appending items or adding
unread counts. Older snapshot revisions and responses from an earlier
core/host-selection generation are rejected. Secondary support/report views
are refreshed too. A deleted open chat cannot prevent refreshing the chat list.

The receiver reconciles after shared events and mutation invalidations. While
linked, an idle receiver also reconciles every five seconds: an initiating
coroutine can apply its optimistic result after the event receiver already
processed a newer peer mutation. This sweep repairs that command-response/event
race. Normal peer updates are event driven. This implementation deliberately
trades additional snapshot traffic for convergence without a global command
lock; large chats and file-progress bursts need performance testing.

A paused phone receiver cannot block core commands or the remote subscriber.
Local overflow atomically discards stale deltas and inserts an explicit
`overflow` invalidation. The resumed receiver resnapshots before continuing its
normal projection, recovers hosted-session state and pending call invitations,
and rechecks unfinished platform-store transactions. Snapshot failures remain
pending and retry on idle receives. A remote subscriber overflow invalidates
that session, revokes its admission token and disconnects it. A newly verified
session takes a fresh snapshot before normal viewing, including messages received
while it was away. Trusted direct links recover using fresh authenticated
sessions, as described in the [recovery protocol](../tailscale-device-linking.md).

Profile identity is frozen from hosted pairing admission through disconnect:
creation, selection and deletion return `remoteCtrl busy` while linked. A narrow
profile/pairing gate makes the admission check safe against profile selection.
Ordinary commands, snapshots, file requests and long polling do not acquire it.
Authenticated remote commands hold concurrent counted leases on the profile.
After unlink, a profile change waits for already-admitted commands to finish or
cancel; it cannot select a new implicit user underneath them. Lease admission
checks revocation atomically, and bracketed cleanup releases leases on failures
and cancellation. Remote identity mutations are rejected before taking the
profile gate, avoiding a gate/lease wait cycle.
Disconnect first to switch profiles. This conservative restriction prevents
implicit-user commands or stale file requests from operating under a different
profile. Existing per-chat/entity/store locking remains in use.

## Side effects and Android lifecycle

- The phone owns background message/contact notifications. The desktop viewer
  does not emit a second background notification or create notification actions
  against its own database. Mirrored sent items never create received-message
  notifications. Authoritative read snapshots cancel phone notifications for
  chats whose unread count is zero.
- The phone alone automatically accepts incoming media attachments using its preferences.
  The desktop can request file acceptance explicitly over XRCP. File bytes and
  paths remain on the phone, and the viewer fetches them through encrypted XRCP.
  Hosting a controller does not make the phone use remote paths. Viewer events
  do not run cleanup against desktop-local paths.
- Calls can originate on the phone or a linked desktop. Incoming invitations
  ring on all connected UIs. Before opening media, the answering UI claims the
  call under the contact lock using its invitation UUID; only one device can
  claim it, and stale invitations cannot claim a replacement call. The core binds a
  desktop owner to the authenticated session sequence, never to client input.
  Initial invitations, including the key needed to answer, are shared with
  the authorized UIs that can claim the call. Subsequent offers, answers and
  ICE are routed only to the owner, and other devices stop ringing. Other UIs cannot answer, update or end an owned call. Disconnecting
  its desktop ends that call, without moving media to the phone or affecting
  another desktop. Transferring a live call between UIs is outside this protocol.
- The connection modal starts the Android foreground messaging service. Closing
  it leaves the verified session and phone chat UI running. Service safe-stop
  refuses to stop while a hosted session exists, including when the ordinary
  notification mode is off. Explicit remote-service start is allowed when chat
  notification display is disabled. Disconnect/unlink clears session state and
  releases this service requirement. Disconnect does not reload the phone model
  as a handoff or close unrelated modals. Android force-stop/process death ends
  the in-process session; enabled trusted direct links resume after database unlock.
- Unlinking the active controller revokes its queue/admission token before
  transport cleanup and deletes its pairing. The phone continues receiving.
  Already admitted commands can finish during revocation under their original
  profile; this is not transaction rollback. Crypto/session keys and request authentication retain
  the existing XRCP implementation.
- A revoked or overflowed event stream returns the typed XRCP
  `sessionClosed` protocol error. It is terminal: the viewer ends polling and
  emits one sequence-bound `remoteHostStopped` callback before a fresh session
  and snapshot can recover. Corrupt-body and other receive failures also end
  polling, retaining their error in the stop reason instead of retrying and
  flooding the UI. Polling starts after the connected callback is published.

## Recovery and validation

Recovery retains authenticated persisted authorization and sequence ownership.
A replacement session creates a fresh protocol-2 buffer and the viewer takes an
authoritative snapshot before resuming deltas. Explicit stop/unlink revokes
admission and authorization, and Android service retention covers both hosted
sessions and authorized retries. Lost requests are cancelled with the old
session; uncertain sends are never replayed automatically.

`tests/RemoteTests.hs` covers independent receivers, concurrent mutations,
local and remote overflow, profile leases, revocation, snapshots and interrupted
requests. `tests/ConcurrentTests.hs` also runs as the standalone
`simultaneous-ui-core-test` suite. Kotlin model tests cover notification
ownership, attachment replacement, stale generations/revisions, reconnection
ownership and structured connection errors.

Run the remote suite with `SIMPLEX_TEST_PORT_BASE` set to an available base port.
Multicast discovery needs a network environment that supports it. Matching
native and Kotlin sources must be built together before testing the apps.

Physical acceptance should cover concurrent send/edit/delete/read, incoming
files, phone-owned message notifications and device-owned calls, phone
backgrounding, network outages,
application restarts, explicit disconnect and unlink during active requests.
Snapshot detail is bounded to 10,000 items; preserving arbitrary older paging,
scroll position and very large-chat performance need further validation.
Notifications and in-progress call signalling lost during local overflow are
not durable event replay: snapshots restore persisted state and pending
invitations, not expired platform alerts or WebRTC signalling history.
