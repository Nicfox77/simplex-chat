# Development workflow

Read `docs/CONTRIBUTING.md`, `docs/contributing/PROJECT.md`,
`docs/contributing/CODE.md`, and `scripts/ci/README.md` before implementation.
Use the relevant app README for platform work. Upstream PRs target `master`.

## Heavy execution

Use the configured Workpool for heavy builds and test suites. Cabal and Gradle
are not covered by its automatic command shims; do not launch their heavy work
directly on the workstation or create an unrestricted local fallback.

- `scripts/ci/workpool/device-build.sh linux` runs Kotlin checks and packages Linux.
- `scripts/ci/workpool/device-build.sh android` builds the matching Android arm64 APK.
- The immutable worker image is pinned in `scripts/ci/workpool/image.txt`.
- For other suites, submit an explicit bounded `workpool run` using that image.
- Use `workpool status`/`wait` with the recorded job ID. Inspect uncertain outcomes
  before retrying; a disconnected client does not mean the remote job stopped.

Small source inspections, shell/YAML checks and the standalone concurrency
checks may run locally. The local GitHub runner's `local_checks` mode is for
those small checks; it does not inherit the operator's Workpool SSH credentials.

## Linked-device architecture

The phone owns the chat database, encryption state and messaging connections.
Desktops control/view that phone over authenticated XRCP. Preserve pairing,
revocation and per-session event ownership. Test both Kotlin and native core
from the same source; do not substitute release native libraries or disable
protocol capability checks to make a test package start.
