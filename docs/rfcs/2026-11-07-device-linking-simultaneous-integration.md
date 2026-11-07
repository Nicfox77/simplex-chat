# Device linking and simultaneous UI integration

This is a local integration snapshot on `integration/simplex-tailscale-and-dualui-20261106`.
Only this isolated checkout and integration branch were changed. No feature
branch or stable checkout was written, and no push, PR creation or master merge
was performed.

Inputs:

- PR #1: `feature/tailscale-device-linking`, `f3f11dc3654a89508691662e7b044e69de4b6e9a`.
- PR #2: `feature/simultaneous-device-ui`, `0302c406bce37c7b299ad611b2b4ef79ce7a46f8`.
- XRCP dependency: `Nicfox77/simplexmq`, `10e75b56891deef9064474265208ba39beb08dd9`.

The initial uncommitted merge used PR #1's earlier `3b78d96e8` head. Once its
final worker pushed, the merge was restarted against `f3f11dc365`, preserving
the reviewed resolutions with a three-way reconciliation of the final changes.
The integration commit is a regular git merge with the exact two input heads
as parents; no rebase or feature-branch rewrite is involved.

## Conflict resolutions and integration fixes

- `.github/workflows/android-emu.yml`: retain both PR #1's scoped PR trigger
  and PR #2's reusable workflow inputs. Non-PR callers may run the plan job.
- `apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/views/remote/ConnectDesktopView.kt`:
  keep the simultaneous session when settings close; retain the service while
  a hosted session or authorized retry owner exists.
- `src/Simplex/Chat/Controller.hs`: combine the revocable per-session
  `EventBuffer` with the retained transport's stop-control channel and saved
  recovery endpoint. Preserve fanout, local event ownership and revision state.
- `src/Simplex/Chat/Library/Commands.hs`: retain atomic session unpublication
  and revocation during owner shutdown. Add recovery admission to the existing
  profile lifecycle gate, preserving concurrent command leases and rejecting
  profile transitions while pairing/connected.
- `src/Simplex/Chat/Remote.hs`: negotiate protocol 1 alongside authenticated
  restart/reconnect capabilities. Every verified replacement gets a fresh
  event buffer. Publish Connected before polling; route viewer events through
  the bounded local UI output path. Receive failures end the poller once and
  signal its retained owner; malformed responses remain terminal errors,
  while outages/closed buffers can enter fresh authenticated recovery.
  Explicit stop atomically queues its control message and revokes admission;
  only that stop message may pass the closed-buffer response guard. Overflow
  closes transport before joining workers. Unlink sends the actual session
  sequence with a terminal stop reason, preventing an authorized retry owner
  from interpreting unlink as an outage. Keep the final PR #1 transaction and
  stale-startup authorization checks.
- `tests/RemoteTests.hs`: retain both registrations and adapt session-code
  test values to the new sequence field. Add one stop-after-revocation control
  test and three paired-feature cases: protocol-1 desktop restart, phone
  restart, and overflow recovery via the authenticated stored-pairing endpoint
  followed by snapshot/read/fanout/profile/unlink checks.
- `apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/model/SimpleXAPI.kt`:
  a restored Android link starts the messaging service with `remoteSession = true`,
  including when ordinary chat notifications are disabled.
- `apps/multiplatform/common/src/commonTest/kotlin/chat/simplex/app/RemoteSessionModelTest.kt`:
  verify that an authorized reconnect keeps phone-local file ownership.
- `packages/simplex-chat-client/types/typescript/src/types.ts`: remove one
  inherited trailing space; preserve the merged API definitions.

Notification ownership, automatic file acceptance, calls and phone file paths
retain PR #2's owner/viewer rules. Existing JVM notification and projection tests
and the real encrypted XRCP upload/download cases exercise those boundaries.

## Validation

The final library and test executable compile with GHC 9.6.6 and cabal 3.10.3.0.
Final full Remote result: **181 examples, zero failures, 117 pending**
(64 active passes, 47.98 seconds). Pending cases are the three explicitly
disabled compression variants. Multicast discovery was excluded.
Final concurrency result: **12 examples, zero failures** (0.012 seconds).
Both staged and unstaged `git diff --check` passed. Final commands (from this checkout):

```sh
cabal build simplex-chat-test simultaneous-ui-core-test \
  --builddir=.task-tools/dist-newstyle --ghc-options=-O0 -j2
SIMPLEX_TEST_PORT_BASE=23000 \
  .task-tools/dist-newstyle/build/x86_64-linux/ghc-9.6.6/simplex-chat-7.1.0.20/t/simplex-chat-test/build/simplex-chat-test/simplex-chat-test \
  --match /Remote/ --skip 'connects with multicast discovery' --jobs=2 +RTS -N2 -RTS
.task-tools/dist-newstyle/build/x86_64-linux/ghc-9.6.6/simplex-chat-7.1.0.20/t/simultaneous-ui-core-test/build/simultaneous-ui-core-test/simultaneous-ui-core-test
ANDROID_HOME=/tmp/simplex-integration-android-sdk apps/multiplatform/gradlew \
  -p apps/multiplatform :common:desktopTest :desktop:compileKotlinJvm \
  -x :desktop:cmakeBuildAndCopy --no-daemon --max-workers=1 \
  -Dorg.gradle.jvmargs='-Xmx3g -Dfile.encoding=UTF-8' \
  -Pkotlin.compiler.execution.strategy=in-process
ANDROID_HOME=/tmp/simplex-integration-android-sdk apps/multiplatform/gradlew \
  -p apps/multiplatform :common:compileDebugKotlinAndroid :android:compileFossDebugKotlin \
  --no-daemon --max-workers=1 \
  -Dorg.gradle.jvmargs='-Xmx3g -Dfile.encoding=UTF-8' \
  -Pkotlin.compiler.execution.strategy=in-process
git diff --check
git diff --cached --check
```

Desktop: 291 tests, zero failures/errors/skips; common and desktop app Kotlin
compilation succeeded. Android common and FOSS app Kotlin compilation succeeded
(37 tasks; native packaging was not part of these targets). JVM builds used one
worker and one 3 GB compiler JVM. Native packaging was attempted by the initial
desktop compile dependency and failed at CMake's empty native-library glob;
the successful Kotlin run excludes that prerequisite explicitly.

Tests used separate ports and a checkout-local `tests/tmp` symlink to
`/dev/shm/simplex-integration-327a`, avoiding slow on-disk SQLite fixtures and
any other worktree's test directories. Source/dependency caches and Android SDK
copies are local to this checkout or its dedicated temporary directory.
Local logs are under `.task-tools/`; they are ignored build artifacts:
`build-final.log`, `remote-final.log`, `concurrency-final.log`,
`desktop-final.log`, `android.log`. The first Remote run exposed a test harness
expectation: deliberately attempting recovery of a deleted pairing emits its
own new-sequence stop callback. The paired test now asserts that callback
before checking subsequent phone messages; no production behavior was relaxed.

## Final source-boundary verification

At `2026-11-07T03:51:38Z`, a fresh origin fetch and local-ref comparison found:

- PR #1 local and origin: `f3f11dc3654a89508691662e7b044e69de4b6e9a`.
- PR #2 local and origin: `0302c406bce37c7b299ad611b2b4ef79ce7a46f8`.
- Stable checkout branch: `79d91e716dbb8aae80327f580aac9a6b42426466`.

No new source commits remained to merge. Both feature heads remain at these
final input SHAs; this integration did not move either feature branch. The
only feature-head advance during this work was PR #1's independently authored
final worker commit, which is included as the merge parent. This local
snapshot does not publish or merge either draft PR. To identify its exact
commit and tree, run `git rev-parse HEAD HEAD^{tree}` on this integration branch.

## Remaining acceptance work

Kotlin compilation does not establish an Android native build or APK. This
checkout has no rebuilt matching Android `libsimplex.so`; no APK/native-link
success or physical Android/Linux pairing is claimed. Desktop CMake also needs
a matching native library, so its prerequisite is excluded for Kotlin-only
compilation. Run both apps with native libraries built from this integration
before physical acceptance.

Multicast discovery requires a suitable network and is excluded in this
container. The three upstream-disabled compression variants remain pending.
Physical screen-off/service restart, OS notification delivery, attachment
opening, calls, large-chat performance and GUI pairing remain to be exercised.
See the acceptance steps in `2026-11-06-simultaneous-device-ui.md`.

## Exact imported/changed file inventory relative to PR #2

```text
.github/workflows/android-emu.yml
.gitignore
apps/multiplatform/common/src/androidMain/kotlin/chat/simplex/common/platform/DirectDeviceLinking.android.kt
apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/model/ChatModel.kt
apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/model/DirectLinkReconnect.kt
apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/model/SimpleXAPI.kt
apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/platform/DirectDeviceLinking.kt
apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/views/remote/ConnectDesktopView.kt
apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/views/remote/ConnectMobileView.kt
apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/views/remote/RemoteLinkSettings.kt
apps/multiplatform/common/src/commonMain/moko-resources/base/strings.xml
apps/multiplatform/common/src/commonTest/kotlin/chat/simplex/app/RemoteSessionModelTest.kt
apps/multiplatform/common/src/desktopMain/kotlin/chat/simplex/common/platform/DirectDeviceLinking.desktop.kt
apps/multiplatform/common/src/desktopTest/kotlin/chat/simplex/app/DirectLinkReconnectTest.kt
apps/multiplatform/common/src/desktopTest/kotlin/chat/simplex/app/RemoteLinkSettingsTest.kt
apps/multiplatform/product/README.md
apps/multiplatform/product/concepts.md
apps/multiplatform/spec/architecture.md
apps/multiplatform/spec/impact.md
bots/api/COMMANDS.md
bots/api/EVENTS.md
bots/api/TYPES.md
bots/src/API/Docs/Commands.hs
cabal.project
docs/rfcs/2026-11-06-simultaneous-device-ui.md
docs/rfcs/2026-11-07-device-linking-simultaneous-integration.md
docs/tailscale-device-linking.md
packages/simplex-chat-client/types/typescript/src/events.ts
packages/simplex-chat-client/types/typescript/src/responses.ts
packages/simplex-chat-client/types/typescript/src/types.ts
packages/simplex-chat-python/src/simplex_chat/types/_events.py
packages/simplex-chat-python/src/simplex_chat/types/_responses.py
packages/simplex-chat-python/src/simplex_chat/types/_types.py
scripts/ci/desktop-linux/build-backend.sh
scripts/ci/ios-sim/build-backend.sh
scripts/nix/sha256map.nix
simplex-chat.cabal
src/Simplex/Chat/Controller.hs
src/Simplex/Chat/Library/Commands.hs
src/Simplex/Chat/Remote.hs
src/Simplex/Chat/Remote/Types.hs
src/Simplex/Chat/Store/Postgres/Migrations.hs
src/Simplex/Chat/Store/Postgres/Migrations/M20261106_remote_link_recovery.hs
src/Simplex/Chat/Store/Postgres/Migrations/chat_schema.sql
src/Simplex/Chat/Store/Remote.hs
src/Simplex/Chat/Store/SQLite/Migrations.hs
src/Simplex/Chat/Store/SQLite/Migrations/M20261106_remote_link_recovery.hs
src/Simplex/Chat/Store/SQLite/Migrations/chat_schema.sql
tests/RemoteTests.hs
```
