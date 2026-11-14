#!/usr/bin/env bash
# Docker's installed Workpool shim builds this toolchain on an admitted host.
set -euo pipefail
cd "$(dirname "$0")/../../.."
docker_wrapper=$(readlink -f "$(command -v docker)")
if [[ "$docker_wrapper" != */workpool-command ]]; then
  echo 'Install the Workpool Docker shim before building the toolchain image.' >&2
  exit 1
fi
image_context=$(mktemp -d)
trap 'rm -rf "$image_context"' EXIT
cp Dockerfile.build "$image_context/Dockerfile"
cat >> "$image_context/Dockerfile" <<'DOCKERFILE'

USER root
RUN mkdir -p /etc/nix && printf '%s\n' \
    'sandbox = false' \
    'build-users-group =' \
    'experimental-features = nix-command flakes' \
    'substituters = https://cache.nixos.org https://cache.zw3rk.com https://cache.iog.io' \
    'trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk= hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=' \
    > /etc/nix/nix.conf && \
    chown 65534:65534 /nix /home/builder /home/builder/.android /home/builder/.gradle
USER 65534:65534
WORKDIR /home/builder
RUN curl --proto '=https' --tlsv1.2 -sSf https://releases.nixos.org/nix/nix-2.22.0/install -o /tmp/nix-install && \
    echo '4fed7db867186c01ce2a2077da4a6950ed16232efbf78d0cd19700cff80559f9  /tmp/nix-install' | sha256sum -c - && \
    sh /tmp/nix-install --no-daemon && chmod g-s /nix/store && rm /tmp/nix-install
ENV PATH="/home/builder/.nix-profile/bin:$PATH"
WORKDIR /workspace
DOCKERFILE
printf '%s\n' '{"memory_gib":4,"cpus":0.5,"timeout":10800}' > "$image_context/.workpool.json"
cd "$image_context"
docker build --progress=plain -t simplex-device-build:20261113 .
docker image inspect simplex-device-build:20261113 --format '{{json .RepoDigests}}'
