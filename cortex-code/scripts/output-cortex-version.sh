#!/usr/bin/env bash

# Print the installed Cortex Code CLI version and expose it as a step output.
#
# Shared by the root action and the cortex-code leaf action so the version-string
# parsing and install-location assumption live in one place.

set -euo pipefail

export PATH="${HOME}/.local/bin:$PATH"
VERSION=$(cortex --version 2>&1 | head -1)
echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
echo "Cortex Code CLI: ${VERSION}"
