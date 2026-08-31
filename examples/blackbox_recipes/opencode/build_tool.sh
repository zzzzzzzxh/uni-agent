#!/usr/bin/env bash
# Build the pinned OpenCode sidecar image.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${TOOL_IMAGE:-opencode-tool}"
IMAGE_TAG="${TOOL_TAG:-latest}"
OPENCODE_VERSION="${OPENCODE_VERSION:-1.18.25}"
OPENCODE_TARGET="${OPENCODE_TARGET:-linux-x64}"
OPENCODE_URL="${OPENCODE_URL:-}"
OPENCODE_SHA256="${OPENCODE_SHA256:-}"
REGISTRY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="$2"; shift 2 ;;
    --version) OPENCODE_VERSION="$2"; shift 2 ;;
    --target) OPENCODE_TARGET="$2"; shift 2 ;;
    --url) OPENCODE_URL="$2"; shift 2 ;;
    --sha256) OPENCODE_SHA256="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
ARGS=(--build-arg "OPENCODE_VERSION=${OPENCODE_VERSION}" --build-arg "OPENCODE_TARGET=${OPENCODE_TARGET}" --build-arg "OPENCODE_SHA256=${OPENCODE_SHA256}")
[[ -n "$OPENCODE_URL" ]] && ARGS+=(--build-arg "OPENCODE_URL=${OPENCODE_URL}")
echo "==> Building ${IMAGE_NAME}:${IMAGE_TAG} (version=${OPENCODE_VERSION}, target=${OPENCODE_TARGET})"
docker build -f "$SCRIPT_DIR/Dockerfile.opencode-tool" -t "${IMAGE_NAME}:${IMAGE_TAG}" "${ARGS[@]}" "$SCRIPT_DIR"
if [[ -n "$REGISTRY" ]]; then
  FULL_TAG="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
  docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "$FULL_TAG"
  docker push "$FULL_TAG"
  echo "Pushed: $FULL_TAG"
fi

