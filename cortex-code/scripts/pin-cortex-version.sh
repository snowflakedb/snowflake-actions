#!/usr/bin/env bash

# Pin the Cortex Code CLI to a specific version.
#
# Shared by the root action and the cortex-code leaf action so the install
# location assumption (${HOME}/.local/bin) lives in one place.
#
# Env:
#   CORTEX_VERSION        Version to pin (e.g. "1.5.2").
#   CORTEX_BINARY         Set when the caller passed a local executable.
#   CORTEX_INSTALL_MODE   local, preinstalled, or downloaded. From install-cortex.sh.
#                         Only a fresh download may be pinned. A published archive
#                         for that version is installed from the archive. Otherwise
#                         the installed CLI runs `cortex update`. A local binary or
#                         a cortex already on PATH fails here, before either step.

set -euo pipefail

CORTEX_BINARY="${CORTEX_BINARY:-}"
CORTEX_INSTALL_MODE="${CORTEX_INSTALL_MODE:-}"

if [ -n "$CORTEX_BINARY" ] || [ "$CORTEX_INSTALL_MODE" = "local" ]; then
    echo "::error::cortex-binary cannot be combined with a pinned version. Pinning runs 'cortex update', which reaches the network, and would ignore the local binary."
    exit 1
fi

if [ "$CORTEX_INSTALL_MODE" != "downloaded" ]; then
    echo "::error::Refusing to pin Cortex Code (install mode: ${CORTEX_INSTALL_MODE:-unset}). A pin runs 'cortex update', which reaches the network. Leave the version at latest when cortex is already on PATH."
    exit 1
fi

export PATH="${HOME}/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set +e
bash "${SCRIPT_DIR}/cortex-release.sh" --version "${CORTEX_VERSION}"
status=$?
set -e

if [[ "$status" -eq 44 ]]; then
    cortex update "$CORTEX_VERSION"
elif [[ "$status" -ne 0 ]]; then
    exit "$status"
fi
