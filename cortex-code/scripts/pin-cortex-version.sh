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
#                         Pinning is `cortex update`, which reaches the network,
#                         so only a fresh download may be pinned. A local binary
#                         or a cortex already on PATH fails here, before update.
#                         That matches the CLI rejecting cli-artifact plus a version.

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
cortex update "$CORTEX_VERSION"
