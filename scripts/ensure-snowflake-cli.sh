#!/usr/bin/env bash

# Ensure the Snowflake CLI (snow) is available, installing it only if absent.
#
# This is the seam for self-contained capability actions (e.g. a future dcm
# action) that need `snow` but must NOT require the consumer to run
# snowflakedb/snowflake-actions first. If `snow` is already on PATH (a prior
# step or the root action installed it), this is a no-op and the existing
# install — including any pinned version — is left untouched. Otherwise it
# installs the latest release via the shared installer.
#
# NOTE: the install path runs `uv tool install` (see install-snowflake-cli.sh),
# so a caller that may hit that path must run astral-sh/setup-uv beforehand.
# When `snow` is already present, `uv` is not needed.

set -euo pipefail

if command -v snow &>/dev/null; then
    echo "Snowflake CLI already available: $(snow --version 2>/dev/null | head -1). Reusing it."
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Snowflake CLI not found; installing the latest release."
bash "${SCRIPT_DIR}/install-snowflake-cli.sh"
