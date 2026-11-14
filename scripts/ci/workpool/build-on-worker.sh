#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
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
exec scripts/ci/local-device-build.sh "${1:?choose linux or android}"
