#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p "$HOME"
export GRADLE_USER_HOME="$HOME/.gradle"
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Duser.home=$HOME"
# Jobs have no host credentials or Cabal cache. Use HTTPS for the public index.
export CABAL_CONFIG=/tmp/simplex-cabal/config
mkdir -p /tmp/simplex-cabal
cat > "$CABAL_CONFIG" <<'CABAL'
repository hackage.haskell.org
  url: https://hackage.haskell.org/
  secure: True
remote-repo-cache: /tmp/simplex-cabal/packages
store-dir: /tmp/simplex-cabal/store
jobs: 2
CABAL
mkdir -p artifacts
printf '%s\n' "source=${2:-unknown}" "target=${1:-unknown}" > artifacts/BUILD_SOURCE.txt
# The Android flake uses cleanGit; snapshots deliberately omit host Git data.
if [[ "${1:-}" == android ]] && ! git rev-parse --git-dir >/dev/null 2>&1; then
  git init --quiet
  git add --all
  git -c user.name='Workpool Snapshot' -c user.email=workpool@localhost \
    -c commit.gpgsign=false commit --quiet -m 'filesystem snapshot'
fi
if [[ "${1:-}" == linux ]]; then
  (
    cd apps/multiplatform
    ./gradlew --no-daemon --max-workers=1 -Pkotlin.compiler.execution.strategy=in-process \
      '-Dorg.gradle.jvmargs=-Xmx3g -Dfile.encoding=UTF-8' \
      :common:desktopTest :desktop:compileKotlinJvm -x :desktop:cmakeBuildAndCopy \
      :android:compileFossDebugKotlin
  )
  mkdir -p artifacts/kotlin-test-results
  cp apps/multiplatform/common/build/test-results/desktopTest/*.xml artifacts/kotlin-test-results/
fi
exec scripts/ci/local-device-build.sh "${1:?choose linux or android}"
