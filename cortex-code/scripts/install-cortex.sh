#!/usr/bin/env bash

# Install the Cortex Code CLI.
#
# Offline / air-gapped runners: set CORTEX_BINARY to a local executable, or
# preinstall `cortex` on PATH. Either path skips the release-archive download.
# A pinned version fails in both cases, because pinning reaches the network.
# Leave the version at latest when offline. CORTEX_BINARY cannot be combined
# with a pin.
#
# Writes install_mode=local|preinstalled|downloaded to $GITHUB_OUTPUT so the
# pin step can fail before a download without guessing from PATH (after
# this script, cortex is on PATH in every successful mode).
#
# Env:
#   CORTEX_CHANNEL   stable or beta (default stable). Ignored when CORTEX_BINARY
#                    is set or cortex is already on PATH.
#   CORTEX_BINARY    Path to a local cortex executable. Copied into ~/.local/bin.

set -euo pipefail

CORTEX_CHANNEL="${CORTEX_CHANNEL:-stable}"
CORTEX_BINARY="${CORTEX_BINARY:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="${HOME}/.local/bin:${PATH}"
mkdir -p "${HOME}/.local/bin"

if [ -n "$CORTEX_BINARY" ]; then
    if [ ! -f "$CORTEX_BINARY" ]; then
        echo "::error::cortex-binary not found: ${CORTEX_BINARY}"
        exit 1
    fi
    cp "$CORTEX_BINARY" "${HOME}/.local/bin/cortex"
    chmod 0755 "${HOME}/.local/bin/cortex"
    install_mode=local
    echo "Installed Cortex Code from local binary; did not download a release archive."
elif command -v cortex >/dev/null 2>&1; then
    install_mode=preinstalled
    echo "cortex already on PATH ($(command -v cortex)); skipping the release-archive download."
else
    install_mode=downloaded
    echo "Installing Cortex Code CLI (channel: ${CORTEX_CHANNEL})..."
    bash "${SCRIPT_DIR}/cortex-release.sh" --channel "$CORTEX_CHANNEL"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "install_mode=${install_mode}" >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_PATH:-}" ]; then
    echo "${HOME}/.local/bin" >> "$GITHUB_PATH"
fi
export PATH="${HOME}/.local/bin:${PATH}"
cortex --version
