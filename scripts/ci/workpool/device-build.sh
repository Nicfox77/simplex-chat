#!/usr/bin/env bash
# Explicitly offload Cabal/Gradle, which do not have automatic Workpool profiles.
set -euo pipefail
cd "$(dirname "$0")/../../.."
pool_image=${1:?provide an installed image with an immutable digest}
build_target=${2:?choose linux or android}
case "$build_target" in linux|android) ;; *) echo 'Choose linux or android' >&2; exit 2 ;; esac
source_revision=$(git rev-parse HEAD)
if [[ -n $(git status --porcelain) ]]; then source_revision+=+dirty; fi
exec workpool run --cwd "$PWD" --image "$pool_image" \
  --memory-gib 4 --cpus 1 --timeout 10800 --queue-timeout 900 \
  --artifact artifacts -- scripts/ci/workpool/build-on-worker.sh "$build_target" "$source_revision"
