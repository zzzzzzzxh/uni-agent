#!/bin/sh
set -eu
ROOT="/opt/codex"
export CODEX_MANAGED_PACKAGE_ROOT="${CODEX_MANAGED_PACKAGE_ROOT:-${ROOT}}"
exec "${ROOT}/vendor/x86_64-unknown-linux-musl/bin/codex" "$@"
