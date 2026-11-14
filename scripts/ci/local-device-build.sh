#!/usr/bin/env bash
# Package matching native code and Kotlin UI on a provisioned local runner.
set -euo pipefail
cd "$(dirname "$0")/../.."
target=${1:?usage: local-device-build.sh linux or android}
case "$target" in
  linux) minimum_gb=15 ;;
  android) minimum_gb=40 ;;
  *) echo "Unknown target: $target" >&2; exit 2 ;;
esac
if [[ "$target" == android && -e apps/multiplatform/local.properties ]]; then
  echo 'Use a clean checkout: apps/multiplatform/local.properties already exists.' >&2
  exit 1
fi
available_kb=$(df -Pk . | awk 'NR == 2 {print $4}')
if (( available_kb < minimum_gb * 1024 * 1024 )); then
  echo "Need at least $minimum_gb GB free for $target; no build started." >&2
  exit 1
fi
: "${ANDROID_HOME:?Set ANDROID_HOME to a provisioned Android SDK}"
for tool in java cmake ninja; do command -v "$tool" >/dev/null; done
mkdir -p artifacts
artifacts=$(cd artifacts && pwd)
if [[ "$target" == linux ]]; then
  for tool in ghc cabal patchelf; do command -v "$tool" >/dev/null; done
  if [[ ! -f cabal.project.local ]]; then
    cp scripts/cabal.project.local.linux cabal.project.local
    printf '\njobs: 2\n' >> cabal.project.local
  fi
  SKIP_VLC=1 scripts/desktop/build-lib-linux.sh
else
  command -v nix >/dev/null
  native_dir=$(mktemp -d)
  trap 'rm -rf "$native_dir"' EXIT
  for component in simplex-chat support; do
    nix --extra-experimental-features 'nix-command flakes' build -L --cores 2 --max-jobs 2 \
      --out-link "$native_dir/result-$component" \
      ".#hydraJobs.x86_64-linux.aarch64-android:lib:$component"
    unzip -o "$native_dir/result-$component"/pkg-*.zip -d "$native_dir/libs"
  done
  tar -C "$native_dir/libs" -czf "$native_dir/core.tar.gz" .
  scripts/ci/android/install-core.sh "$native_dir/core.tar.gz"
fi
cd apps/multiplatform
if [[ "$target" == android ]]; then
  printf '%s\n' 'application_id.suffix=.devlink' 'app.name=SimpleX Device Test' > local.properties
  ./gradlew --no-daemon --max-workers=1 -Pkotlin.compiler.execution.strategy=in-process \
    '-Dorg.gradle.jvmargs=-Xmx3g -Dfile.encoding=UTF-8' \
    -Pandroid.injected.build.abi=arm64-v8a :android:assembleFossDebug
  package_artifact=android-foss-arm64-v8a-debug.apk
  cp "android/build/intermediates/apk/foss/debug/$package_artifact" "$artifacts/"
else
  ./gradlew --no-daemon --max-workers=1 -Pkotlin.compiler.execution.strategy=in-process \
    '-Dorg.gradle.jvmargs=-Xmx3g -Dfile.encoding=UTF-8' :desktop:createDistributable
  package_artifact=desktop-app.tar.gz
  tar -czf "$artifacts/$package_artifact" -C release/main/app simplex
fi
cd "$artifacts"
sha256sum "$package_artifact" > "$package_artifact.sha256"
