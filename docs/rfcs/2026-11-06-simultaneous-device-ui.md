# Simultaneous Android phone and Linux desktop UI

Status: implemented behind the negotiated UI protocol 1, enabled by the Kotlin
apps at core startup. PR #2 remains draft for native builds and physical testing.

The Android phone is the only owner of the database, ratchets, agent and network
connections. The Linux desktop uses authenticated, encrypted XRCP commands,
events and file transfer. There is no second synchronized database, shared
SQLite file, new cryptographic scheme, or change to network reconnection policy.
Both devices need the core and Kotlin code from this branch. An old native
library fails the startup capability check; a peer without UI protocol 1 fails
pairing. Updating just the APK/JAR sources with release native libraries is not
sufficient.

## Delivery and reconciliation

The phone's local receiver and the authenticated desktop session have independent
bounded event queues. Eligible asynchronous events are fanned out atomically to
both; they never compete to read the same queue. Platform-store callbacks,
pairing/lifecycle events and call signalling stay on the phone. Command replies
and errors return only through the initiating request. Successful send, edit,
delete, read/unread, reaction, contact/group and file acceptance mutations publish
`uiStateChanged` invalidations with protocol version, revision and explicit
`local`/`remote` origin. Both frontends reconcile their projections; the reply
payload is never broadcast as an unsolicited notification.

`/_ui enable` opts a Kotlin frontend into protocol 1 before pairing. Legacy
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
while it was away. There is no transparent reconnect in this change.

Profile identity is frozen from hosted pairing admission through disconnect:
creation, selection and deletion return `remoteCtrl busy` while linked. A narrow
profile/pairing gate makes the admission check safe against profile selection.
Ordinary commands, snapshots, file requests and long polling do not acquire it.
Disconnect first to switch profiles. This conservative restriction prevents
implicit-user commands or stale file requests from operating under a different
profile. Existing per-chat/entity/store locking remains in use.

## Side effects and Android lifecycle

- The phone owns background message/contact notifications. The desktop viewer
  does not emit a second background notification or create notification actions
  against its own database. Mirrored sent items never create received-message
  notifications. Authoritative read snapshots cancel phone notifications for
  chats whose unread count is zero.
- The phone alone automatically accepts incoming media using its preferences.
  The desktop can request file acceptance explicitly over XRCP. File bytes and
  paths remain on the phone, and the viewer fetches them through encrypted XRCP.
  Hosting a controller does not make the phone use remote paths. Viewer events
  do not run cleanup against desktop-local paths.
- The phone owns WebRTC calls; remote call commands and call signalling are not
  admitted/routed to the viewer. Desktop call controls are disabled while
  viewing a phone. Transferring a live call between UIs is outside this protocol.
- The connection modal starts the Android foreground messaging service. Closing
  it leaves the verified session and phone chat UI running. Service safe-stop
  refuses to stop while a hosted session exists, including when the ordinary
  notification mode is off. Explicit remote-service start is allowed when chat
  notification display is disabled. Disconnect/unlink clears session state and
  releases this service requirement. Disconnect does not reload the phone model
  as a handoff or close unrelated modals. Android force-stop/process death ends
  the in-process session; pair again after restarting.
- Unlinking the active controller revokes its queue/admission token before
  transport cleanup and deletes its pairing. The phone continues receiving.
  Already admitted commands may have committed before revocation; this is not
  transaction rollback. Crypto/session keys and request authentication retain
  the existing XRCP implementation.

## Validation and remaining physical checks

Validated locally on 2026-11-06:

- The complete Haskell library compiles with GHC 9.6.6.
- The remote suite passed 41 active examples, zero failures, excluding multicast
  discovery on this container. There were 66 pending examples from the three
  upstream-disabled compression variants. These include real encrypted XRCP
  uploads/downloads, concurrent sends/read ownership and session shutdown.
- Three protocol-1 simultaneous cases now pass: both event receivers active
  during sends, edits/deletes and reads/manual unread; a paused local subscriber
  overflowing without blocking remote delivery; and remote overflow followed by
  a new session/snapshot while the phone keeps receiving. The third case was
  added after the full remote run above and passed in a focused rerun.
- Common/desktop Kotlin compilation and 259 tests passed before the last
  reconciliation refinements. The snapshot tests cover item/counter idempotence,
  edits/deletes/reads and wire decoding. Additional revision/generation and
  delayed-command-result tests are included for CI.
- Android compilation reached the common Android Kotlin compiler, then failed
  for insufficient memory. A subsequent process exited 137. The shared cgroup
  records an OOM kill; concurrent builds were running. No Android APK/native
  link success is claimed. Local high-memory retries were stopped. CI Gradle
  steps now use one worker and a single 3 GB compiler JVM.

Core tests can use separate fixture ports so independent worktrees do not
collide:

```sh
SIMPLEX_TEST_PORT_BASE=17000 cabal test simplex-chat-test --ghc-options=-O0 \
  --test-option=-m --test-option='/Remote/' \
  --test-option=--skip --test-option='connects with multicast discovery' \
  --test-option=--jobs=2
cabal test simultaneous-ui-core-test
```

The regular `build.yml` CI compiles/tests Haskell and Kotlin, including Android
Kotlin and desktop sources. This does **not** establish Android native linking
or APK assembly. The manually dispatched `android-emu.yml` and
`desktop-linux.yml` workflows build branch-native libraries, package apps and
run individual app smoke tests. They produce `android-app` and `desktop-app`
artifacts for physical testing. These smoke tests do not pair the two GUIs.
The fork has not registered those workflow files on its default branch, so they
can also be invoked as reusable workflows through the registered build workflow,
without changing the default branch:

```sh
gh workflow run build.yml -R Nicfox77/simplex-chat \
  --ref feature/simultaneous-device-ui -f native_apps=true \
  -f tests='/Remote session/Remote/With compression/simultaneous UI/'
```

Required physical acceptance with those matching builds:

1. Pair/verify, close phone connection settings, then send concurrently from
   both UIs and a third peer. Edit/delete/react from each UI; inspect both loaded
   chats and chat-list previews/counters.
2. Read individual items, whole chats and whole users on each side; toggle
   manual unread. Include timed messages, hidden/multiple profiles (switching
   must be rejected while linked), secondary scopes and scrolled history.
3. Pause/resume the phone receiver and interrupt the desktop transport. Verify
   resnapshot, missed messages and notification cancellation. Reconnect after a
   remote overflow; do not treat a still-disconnected viewer as current.
4. Test screen-off/background, normal notification modes including off, denied
   notification permission, service restart and process death. Confirm the
   phone remains usable while the desktop is connected. Device/OS battery
   restrictions cannot be established by JVM tests.
5. Send/receive images, voice and ordinary files in both directions, explicitly
   accept a file on the desktop, open/download it, and confirm files/cleanup stay
   in the correct device's storage. Check one phone notification per incoming
   message and phone-owned calls without a desktop duplicate.
6. Disconnect and unlink from settings, including while requests/files are in
   flight; confirm the old desktop session is revoked and the phone continues.

Snapshot detail is bounded to 10,000 items; preserving arbitrary older paging,
scroll position and very large-chat performance need physical validation.
Notifications and in-progress call signalling lost during local overflow are
not a durable event replay: snapshots restore persisted state and pending
invitations, not already expired platform alerts or WebRTC signalling history.
Do not mark the draft ready based only on core/terminal or model tests.
