# Simultaneous Android and desktop UI: partial implementation

Status: core foundations and remote-session correctness fixes.
**Simultaneous UI is not enabled.** The
existing linked desktop mode still routes eligible events exclusively to the
desktop, and closing the Android connection modal still disconnects it.

The phone remains the sole owner of the encrypted chat database, agent,
cryptographic sessions and network communication. The desktop continues using
the authenticated remote-control protocol. There is no database sharing,
profile replication, encryption change, iOS change, or new reconnect mechanism.

## Implemented

- Local and paired-controller profile creation commands reaching
  `execChatCommand'` use one controller-owned `profileCreationGate`. The
  duplicate-name check and agent/store allocation span transactions; the gate
  prevents two simultaneous requests from allocating duplicate agent users
  before one fails its store insert. This is separate from existing chat/entity
  locks. Exceptions and cancellation release the gate. Other commands and
  custom-response hooks retain their existing execution behavior. Broad command
  serialization must wait for a nonblocking local subscriber contract: a local
  event reader can itself issue commands, creating a wait cycle if a command
  holds a global gate while filling that reader's blocking `outputQ`.
- Remote events use a bounded `EventBuffer`. Producers never wait for space.
  Overflow invalidates the entire reader and wakes the session monitor, which
  stops the HTTP2 server and linked session. A consumer cannot continue with a
  missing read, deletion or file event. Explicit disposal also closes the buffer
  and wakes pending readers. Each new session gets a fresh buffer.
- `writeEventBuffers` provides atomic, ordered delivery to independent bounded
  subscriber buffers. Tests cover both directions of a paused reader. This
  primitive is **not yet connected to the phone's `outputQ`**. That existing
  queue still has its original blocking behavior.
- Pairing, session lifecycle and platform-store settlement callbacks remain
  local. Only the phone can finish its Android store transactions; sending the
  settlement callback to desktop left the transaction unfinished. Badge state
  changes remain eligible for remote delivery. Command responses still return
  only through their request channel.
- Revoking a hosted controller closes its event buffer in the same STM
  transaction that removes the session. After authenticated request parsing,
  command/file admission checks this lifetime token without waiting for
  transport cancellation. Reply preparation also checks it and suppresses
  payloads and file attachments from revoked sessions. Already admitted work
  may have committed before revocation; this is not transaction rollback.
  Long polling and command/file execution do not share a command gate.
- Controller shutdown unpublishes the remote hosts and current-host selection
  before cancelling transports, as normal explicit disconnect already does.
  Disconnect callbacks cannot recursively cancel the same published session
  during shutdown. Hosted-controller admission is revoked in this same STM
  transaction. Tests stop both the owner and viewer cores with a live session.
- Terminal automatic reads retain the event's remote host ID and execute on
  the owning phone through XRCP. Previously remote item IDs were used against
  the desktop's own database, potentially marking unrelated local items read.
  Local reads retain their original dispatch path. This fixes terminal read
  ownership; it does not add phone/desktop UI read-state broadcasts.
- Kotlin distinguishes viewing a remote phone from hosting a desktop. Hosting
  a desktop does not cause the Android owner to use remote file downloads or
  remote paths. Reopening connection controls preserves an existing session;
  the explicit close confirmation still checks the hosted-controller session.

## Required before enabling simultaneous UI

1. Introduce a versioned frontend subscription/snapshot contract, including a
   watermark or equivalent ordering barrier. Subscribe before taking a snapshot
   and reconcile events without duplicating items or counters. When a local
   reader pauses or overflows, detach/invalidate it and require a fresh snapshot
   before resuming. Do not fan out into two blocking `writeTBQueue` operations.
2. Mirror successful mutations to the *other* UI. Send, edit, delete, reaction,
   contact/group changes and file acceptance often exist only as command
   responses. Map an explicit set of successful results to state events without
   echoing them back to the initiating UI. Preserve route-specific events and
   errors. Blindly broadcasting every response leaks request-specific results
   and duplicates updates already performed by the caller.
3. Add read/unread state events for item reads, chat reads, user reads and
   manually marked-unread chats. Both frontends must update loaded items,
   counts, notifications and timed-item state idempotently. A command gate
   alone cannot reconcile two UI models.
4. Define and implement shared active-profile behavior. The core still has one
   `currentUser`. Serialize selection with commands, then either publish and
   apply the profile change to both frontends or prohibit changes while linked.
   Validate stale user-scoped commands and remote file requests. Never allow a
   stale UI to execute an implicit-user operation under another profile.
5. Give automatic file acceptance and notification side effects one owner.
   Currently both Kotlin event handlers would automatically accept media and
   show alerts if given the same incoming event. Sent items mirrored from the
   other UI must not produce received-message notifications. File bytes remain
   on the phone; the desktop fetches them using the existing encrypted protocol.
6. Bind Android's receiver/service lifetime to the active session rather than
   the modal. Remove close/dispose disconnection only after event delivery,
   snapshots and profile state are safe. Remove handoff reloads and stop closing
   unrelated modals when a desktop disconnects. Keep explicit Disconnect.
7. Test on Android and Linux with a real paired session: concurrent sends,
   edits/deletes/reactions, read propagation, foreground/background transitions,
   stopped receivers, file transfer and profile changes. Coordinate protocol
   version/capability negotiation before shipping with older frontends.

## Validation

The small suite also runs inside the regular `simplex-chat-test` suite:

```sh
cabal test simultaneous-ui-core-test
```

Without building the database/network dependency tree:

```sh
ghc -threaded -Wall -Werror -isrc -itests \
  -outputdir /tmp/simplex-ui-tests tests/ConcurrentMain.hs \
  -o /tmp/simplex-ui-core-test
/tmp/simplex-ui-core-test +RTS -N2
```

This needs GHC plus `stm`, `async` and `hspec`. Twelve examples cover concurrent
mutations, caller-specific results, failure/cancellation, exact ordered delivery
to two buffers, stalled readers, overflow, disposal and fresh-session isolation.
They exercise the shared primitives, not a complete Android/desktop UI flow.

`RemoteTests` additionally checks local-only route policy, request admission
after revocation, long-poll closure, live session shutdown and snapshot recovery
on overflow, unlinking and stale cleanup, and races real local and remote
commands against the same phone store. Read-ownership tests distinguish the
desktop's own unread items from the remote phone's unread items. These are
core/terminal integration tests, not proof of simultaneous Android UI behavior.
`RemoteSessionModelTest`
checks Kotlin file-routing semantics for each role. These require the full core
and Kotlin build environments respectively; record their actual run results
separately from the focused primitive tests.

Validation on 2026-11-06, continuing from the initial draft:

- GHC 9.6.6 compiled the complete chat library and integration-test executable.
  The standalone suite above passed all 12 examples with `-Wall -Werror`.
  `cabal build exe:simplex-chat --ghc-options=-O0` also linked the CLI successfully.
- The remote suite passed **39 active examples, zero failures**, with 60
  pending examples in the three upstream-disabled compression variants. The
  invocation below excludes multicast discovery, which failed in this
  container; discovery/networking code was not changed. Real encrypted XRCP
  sessions, file upload/download, profile changes, both core-stop paths and the
  new concurrency/recovery cases ran. Disposable test databases used tmpfs to
  avoid slow migration fsyncs on this host; the concurrent send/read test also
  passed on the normal filesystem (97 seconds including fixture creation).
- After initializing the pinned NanoHTTPD submodule, Gradle's invocation below
  compiled the common/desktop sources and passed **255 JUnit tests**, including
  both `RemoteSessionModelTest` cases. The default Gradle configuration still
  requires an Android SDK; configuration on demand permits desktop testing
  without it. Unrelated background coroutines logged native `UnsatisfiedLinkError`
  exceptions despite the passing JUnit result. This does not establish JNI or
  Android application runtime correctness.
- Android builds and a real Android/desktop paired UI session remain unverified.
  The missing frontend subscription/snapshot and lifecycle work listed above
  remains unimplemented. Simultaneous UI must stay disabled.

Core/remote validation:

```sh
cabal test simplex-chat-test --ghc-options=-O0 \
  --test-option=-m --test-option='/Remote/' \
  --test-option=--skip --test-option='connects with multicast discovery' \
  --test-option=--jobs=2
```

Kotlin validation (from `apps/multiplatform`):

```sh
./gradlew :common:desktopTest --configure-on-demand --console=plain
```

The narrowed production gate covers only `CreateActiveUser`; inspection found
no UI-event emission or recursive command dispatch in that path. It does not
hold `chatLock`, and ordinary reader-issued commands do not acquire it. The
focused tests verify release after exceptions and both executing/waiting
command cancellation. Frontend integration and Android lifecycle validation
remain required before considering simultaneous UI ready to enable.

## Changed files

- `src/Simplex/Chat/Controller/Concurrent.hs`
- `src/Simplex/Chat/Controller.hs`
- `src/Simplex/Chat.hs`
- `src/Simplex/Chat/Library/Commands.hs`
- `src/Simplex/Chat/Remote.hs`
- `src/Simplex/Chat/Terminal/Output.hs`
- `simplex-chat.cabal`
- `tests/ConcurrentTests.hs`
- `tests/ConcurrentMain.hs`
- `tests/RemoteTests.hs`
- `tests/Test.hs`
- `apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/model/ChatModel.kt`
- `apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/views/remote/ConnectDesktopView.kt`
- `apps/multiplatform/common/src/commonTest/kotlin/chat/simplex/app/RemoteSessionModelTest.kt`
- `docs/rfcs/2026-11-06-simultaneous-device-ui.md`
