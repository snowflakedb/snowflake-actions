#!/usr/bin/env bash

# Pin the Cortex Code CLI to a specific version.
#
# Shared by the root action and the cortex-code leaf action so the install
# location assumption (${HOME}/.local/bin) lives in one place.
#
# Env:
#   CORTEX_VERSION   Version to pin (e.g. "1.5.2").

set -euo pipefail

export PATH="${HOME}/.local/bin:$PATH"
cortex update "$CORTEX_VERSION"
