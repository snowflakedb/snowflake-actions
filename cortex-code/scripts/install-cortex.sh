#!/usr/bin/env bash
set -euo pipefail

CORTEX_CHANNEL="${CORTEX_CHANNEL:-stable}"

echo "Installing Cortex Code CLI (channel: ${CORTEX_CHANNEL})..."

curl -LsS https://ai.snowflake.com/static/cc-scripts/install.sh -o /tmp/cortex-install.sh
SKIP_PODMAN=1 NON_INTERACTIVE=1 CORTEX_CHANNEL="$CORTEX_CHANNEL" sh /tmp/cortex-install.sh
rm -f /tmp/cortex-install.sh

# Add to PATH for subsequent steps
echo "${HOME}/.local/bin" >> "$GITHUB_PATH"

# Make available in current step too
export PATH="${HOME}/.local/bin:$PATH"
cortex --version
