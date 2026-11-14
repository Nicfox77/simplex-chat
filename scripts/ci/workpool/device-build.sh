#!/usr/bin/env bash
# Explicitly offload Cabal/Gradle, which do not have automatic Workpool profiles.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if (( $# == 1 )); then
  pool_image=$(cat scripts/ci/workpool/image.txt)
  build_target=$1
else
  pool_image=${1:?provide an installed image with an immutable digest}
  build_target=${2:?choose linux or android}
fi
case "$build_target" in linux|android) ;; *) echo 'Choose linux or android' >&2; exit 2 ;; esac
pool_artifacts=(--artifact artifacts)
if [[ "$build_target" == android ]]; then pool_artifacts+=(--artifact .signing); fi
pool_memory=6
pool_cpus=1
if [[ "$build_target" == android ]]; then pool_memory=8; pool_cpus=2; fi
source_revision=$(git rev-parse HEAD)
if [[ -n $(git status --porcelain) ]]; then source_revision+=+dirty; fi
exec workpool run --cwd "$PWD" --image "$pool_image" \
  --memory-gib "$pool_memory" --cpus "$pool_cpus" --timeout 10800 --queue-timeout 900 \
  "${pool_artifacts[@]}" -- scripts/ci/workpool/build-on-worker.sh "$build_target" "$source_revision"
