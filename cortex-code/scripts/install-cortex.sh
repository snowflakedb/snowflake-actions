#!/usr/bin/env bash

# Install the Cortex Code CLI.
#
# Offline / air-gapped runners: set CORTEX_BINARY to a local executable, or
# preinstall `cortex` on PATH. Either path skips the download from
# ai.snowflake.com. A pinned version fails in both cases, because pinning
# runs `cortex update` and that reaches the network. Leave the version at
# latest when offline. CORTEX_BINARY cannot be combined with a pin.
#
# Writes install_mode=local|preinstalled|downloaded to $GITHUB_OUTPUT so the
# pin step can fail before `cortex update` without guessing from PATH (after
# this script, cortex is on PATH in every successful mode).
#
# Env:
#   CORTEX_CHANNEL   stable or beta (default stable). Ignored when CORTEX_BINARY
#                    is set or cortex is already on PATH.
#   CORTEX_BINARY    Path to a local cortex executable. Copied into ~/.local/bin.

set -euo pipefail

CORTEX_CHANNEL="${CORTEX_CHANNEL:-stable}"
CORTEX_BINARY="${CORTEX_BINARY:-}"

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
    echo "Installed Cortex Code from local binary; did not contact ai.snowflake.com."
elif command -v cortex >/dev/null 2>&1; then
    install_mode=preinstalled
    echo "cortex already on PATH ($(command -v cortex)); skipping download from ai.snowflake.com."
else
    install_mode=downloaded
    echo "Installing Cortex Code CLI (channel: ${CORTEX_CHANNEL})..."
    curl -LsS https://ai.snowflake.com/static/cc-scripts/install.sh -o /tmp/cortex-install.sh
    SKIP_PODMAN=1 NON_INTERACTIVE=1 CORTEX_CHANNEL="$CORTEX_CHANNEL" sh /tmp/cortex-install.sh
    rm -f /tmp/cortex-install.sh
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "install_mode=${install_mode}" >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_PATH:-}" ]; then
    echo "${HOME}/.local/bin" >> "$GITHUB_PATH"
fi
export PATH="${HOME}/.local/bin:${PATH}"
cortex --version
